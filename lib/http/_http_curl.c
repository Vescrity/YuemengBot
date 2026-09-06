/* _http_curl.c - http 库私有的最小 libcurl C 绑定（仅供 http.lua 内部使用）
 *
 * 异步模型：detached 线程 + socketpair 发信 + 主线程 P.fd 等待。
 *   - start(opts)   主线程读 opts，开 detached 线程跑 curl，返回 req userdata
 *   - req:fd()      返回读端 fd，交给 promise 的 P.fd 等待
 *   - req:finish()  读信号字节后读结果，释放主线程引用
 *
 * 生命周期：request_t 独立分配，userdata 只存指针。主线程与 worker 各持
 * 一个引用计数；计数归零者负责释放。结果字段由 worker 写入，经 socketpair
 * 的 write/read 与内存屏障同步，主线程读信号后才读结果。
 */

#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <curl/curl.h>

/* ---------- 增长缓冲 ---------- */
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} buffer;

static void buf_free(buffer *b) {
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}

static void buf_append(buffer *b, const char *p, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t ncap = b->cap ? b->cap : 4096;
        while (ncap < b->len + n + 1) ncap *= 2;
        char *nd = (char *)realloc(b->data, ncap);
        if (!nd) return;
        b->data = nd;
        b->cap = ncap;
    }
    memcpy(b->data + b->len, p, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    buffer *b = (buffer *)userdata;
    buf_append(b, ptr, size * nmemb);
    return size * nmemb;
}

/* ---------- 全局初始化（主线程） ---------- */
static void ensure_global_init(void) {
    static int inited = 0;
    if (!inited) {
        curl_global_init(CURL_GLOBAL_DEFAULT);
        inited = 1;
    }
}

/* ---------- 请求结构 ---------- */
typedef struct {
    int refs;         /* 主线程 + worker 各 1 */
    pthread_t thread;
    int fd_read;      /* 主线程读信号 */
    int fd_write;     /* worker 写信号后关闭 */

    char *method;
    char *url;
    char *body;
    size_t body_len;
    struct curl_slist *headers;   /* worker 使用并释放 */
    long timeout_ms;
    long connect_timeout_ms;
    long http_version;
    int verify_ssl;
    int follow;

    /* 结果：worker 写，主线程读（写信号后） */
    CURLcode rc;
    long status;
    buffer body_buf;
    buffer header_buf;
} request_t;

/* userdata：只持有指向 request_t 的指针 */
typedef struct {
    request_t *req;
} req_handle_t;

static void req_destroy(request_t *req) {
    free(req->method);
    free(req->url);
    free(req->body);
    if (req->headers) curl_slist_free_all(req->headers);
    buf_free(&req->body_buf);
    buf_free(&req->header_buf);
    free(req);
}

static void req_release(request_t *req) {
    if (__atomic_sub_fetch(&req->refs, 1, __ATOMIC_ACQ_REL) == 0) {
        req_destroy(req);
    }
}

/* ---------- worker 线程 ---------- */
static void *thread_main(void *arg) {
    request_t *req = (request_t *)arg;
    struct curl_slist *slist = req->headers;
    req->headers = NULL;

    CURL *easy = curl_easy_init();
    if (!easy) {
        req->rc = CURLE_FAILED_INIT;
    } else {
        curl_easy_setopt(easy, CURLOPT_URL, req->url);
        curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, req->timeout_ms);
        curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, req->connect_timeout_ms);
        curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, req->follow ? 1L : 0L);
        curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, req->verify_ssl ? 1L : 0L);
        curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, req->verify_ssl ? 2L : 0L);
        curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, req->http_version);
        curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);

        if (strcasecmp(req->method, "GET") == 0) {
            curl_easy_setopt(easy, CURLOPT_HTTPGET, 1L);
        } else if (strcasecmp(req->method, "HEAD") == 0) {
            curl_easy_setopt(easy, CURLOPT_NOBODY, 1L);
        } else if (strcasecmp(req->method, "POST") == 0) {
            curl_easy_setopt(easy, CURLOPT_POST, 1L);
        } else {
            curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, req->method);
        }

        if (req->body != NULL) {
            curl_easy_setopt(easy, CURLOPT_POSTFIELDS, req->body);
            curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE, (long)req->body_len);
        }
        if (slist) {
            curl_easy_setopt(easy, CURLOPT_HTTPHEADER, slist);
        }

        curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb);
        curl_easy_setopt(easy, CURLOPT_WRITEDATA, &req->body_buf);
        curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, write_cb);
        curl_easy_setopt(easy, CURLOPT_HEADERDATA, &req->header_buf);

        req->rc = curl_easy_perform(easy);
        if (req->rc == CURLE_OK) {
            long status = 0;
            curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);
            req->status = status;
        }
        curl_easy_cleanup(easy);
    }

    if (slist) {
        curl_slist_free_all(slist);
    }

    __atomic_thread_fence(__ATOMIC_RELEASE);
    int w = req->fd_write;
    ssize_t n = send(w, "\1", 1, MSG_NOSIGNAL);
    (void)n;
    close(w);

    req_release(req);
    return NULL;
}

/* ---------- 字段白名单校验 ---------- */
static const char *ALLOWED_KEYS[] = {
    "method", "url", "headers", "body", "timeout", "connect_timeout",
    "verify_ssl", "follow_redirects", "http_version", NULL,
};

static int is_allowed(const char *k) {
    for (int i = 0; ALLOWED_KEYS[i]; i++) {
        if (strcmp(ALLOWED_KEYS[i], k) == 0) return 1;
    }
    return 0;
}

static void check_unknown_keys(lua_State *L, int idx) {
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        if (lua_type(L, -2) == LUA_TSTRING) {
            const char *k = lua_tostring(L, -2);
            if (!is_allowed(k)) {
                luaL_error(L, "_http_curl.start: 未知选项 '%s'", k);
            }
        }
        lua_pop(L, 1);
    }
}

static const char *opt_string(lua_State *L, int idx, const char *key,
                              int required, size_t *out_len) {
    lua_getfield(L, idx, key);
    const char *s = lua_tostring(L, -1);
    if (required && s == NULL) {
        luaL_error(L, "_http_curl.start: 缺少 '%s' 字段", key);
    }
    if (s != NULL && out_len) {
        *out_len = (size_t)lua_rawlen(L, -1);
    }
    lua_pop(L, 1);
    return s;
}

static long opt_long(lua_State *L, int idx, const char *key, long def) {
    lua_getfield(L, idx, key);
    long v = def;
    if (!lua_isnil(L, -1)) {
        v = (long)luaL_checkinteger(L, -1);
    }
    lua_pop(L, 1);
    return v;
}

static int opt_bool(lua_State *L, int idx, const char *key, int def) {
    lua_getfield(L, idx, key);
    int v = def;
    if (!lua_isnil(L, -1)) {
        v = lua_toboolean(L, -1);
    }
    lua_pop(L, 1);
    return v;
}

static long parse_http_version(lua_State *L, int idx) {
    lua_getfield(L, idx, "http_version");
    long v = CURL_HTTP_VERSION_2TLS;
    if (lua_isnumber(L, -1)) {
        long n = (long)luaL_checkinteger(L, -1);
        if (n == 1) v = CURL_HTTP_VERSION_1_1;
        else if (n == 2) v = CURL_HTTP_VERSION_2TLS;
        else if (n == 3) v = CURL_HTTP_VERSION_3;
    } else if (lua_type(L, -1) == LUA_TSTRING) {
        const char *s = lua_tostring(L, -1);
        if (s && (strcmp(s, "1") == 0 || strcmp(s, "1.1") == 0)) {
            v = CURL_HTTP_VERSION_1_1;
        } else if (s && strcmp(s, "2") == 0) {
            v = CURL_HTTP_VERSION_2TLS;
        } else if (s && strcmp(s, "3") == 0) {
            v = CURL_HTTP_VERSION_3;
        }
    }
    lua_pop(L, 1);
    return v;
}

/* ---------- start(opts) -> req | nil, err ---------- */
static int l_start(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    check_unknown_keys(L, 1);

    /* 读取选项：此阶段可能抛错，尚未分配资源 */
    const char *method = opt_string(L, 1, "method", 1, NULL);
    const char *url = opt_string(L, 1, "url", 1, NULL);
    size_t body_len = 0;
    const char *body = opt_string(L, 1, "body", 0, &body_len);
    long timeout_ms = opt_long(L, 1, "timeout", 30) * 1000;
    long connect_timeout_ms = opt_long(L, 1, "connect_timeout", 10) * 1000;
    int verify_ssl = opt_bool(L, 1, "verify_ssl", 1);
    int follow = opt_bool(L, 1, "follow_redirects", 1);
    long http_version = parse_http_version(L, 1);

    /* 请求头 -> curl_slist */
    struct curl_slist *slist = NULL;
    lua_getfield(L, 1, "headers");
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            const char *k = lua_tostring(L, -2);
            const char *v = lua_tostring(L, -1);
            if (k && v) {
                size_t klen = strlen(k), vlen = strlen(v);
                char *line = (char *)malloc(klen + vlen + 3);
                if (!line) {
                    lua_pop(L, 1);
                    curl_slist_free_all(slist);
                    lua_pop(L, 1);
                    lua_pushnil(L);
                    lua_pushstring(L, "内存不足");
                    return 2;
                }
                memcpy(line, k, klen);
                line[klen] = ':';
                line[klen + 1] = ' ';
                memcpy(line + klen + 2, v, vlen);
                line[klen + 2 + vlen] = '\0';
                struct curl_slist *tmp = curl_slist_append(slist, line);
                free(line);
                if (!tmp) {
                    lua_pop(L, 1);
                    curl_slist_free_all(slist);
                    lua_pop(L, 1);
                    lua_pushnil(L);
                    lua_pushstring(L, "curl_slist 失败");
                    return 2;
                }
                slist = tmp;
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    /* 分配请求结构 */
    request_t *req = (request_t *)calloc(1, sizeof(request_t));
    if (!req) {
        curl_slist_free_all(slist);
        lua_pushnil(L);
        lua_pushstring(L, "内存不足");
        return 2;
    }
    req->refs = 1;
    req->fd_read = req->fd_write = -1;
    req->headers = slist;
    req->timeout_ms = timeout_ms;
    req->connect_timeout_ms = connect_timeout_ms;
    req->verify_ssl = verify_ssl;
    req->follow = follow;
    req->http_version = http_version;

    req->method = strdup(method);
    req->url = strdup(url);
    if (body != NULL) {
        req->body = (char *)malloc(body_len ? body_len : 1);
        if (body_len) memcpy(req->body, body, body_len);
        req->body_len = body_len;
    }
    if (!req->method || !req->url || (body != NULL && !req->body)) {
        req_destroy(req);
        lua_pushnil(L);
        lua_pushstring(L, "内存不足");
        return 2;
    }

    /* socketpair：读端给主线程，写端给 worker */
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        req_destroy(req);
        lua_pushnil(L);
        lua_pushstring(L, "socketpair 失败");
        return 2;
    }
    req->fd_read = fds[0];
    req->fd_write = fds[1];

    int fl = fcntl(req->fd_read, F_GETFL, 0);
    fcntl(req->fd_read, F_SETFL, fl | O_NONBLOCK);

    ensure_global_init();

    __atomic_add_fetch(&req->refs, 1, __ATOMIC_ACQ_REL); /* worker 引用 */
    if (pthread_create(&req->thread, NULL, thread_main, req) != 0) {
        __atomic_sub_fetch(&req->refs, 1, __ATOMIC_ACQ_REL);
        close(req->fd_read);
        close(req->fd_write);
        req->fd_read = req->fd_write = -1;
        req_destroy(req);
        lua_pushnil(L);
        lua_pushstring(L, "pthread_create 失败");
        return 2;
    }
    pthread_detach(req->thread);

    req_handle_t *h = (req_handle_t *)lua_newuserdata(L, sizeof(req_handle_t));
    h->req = req;
    luaL_getmetatable(L, "http_curl_req");
    lua_setmetatable(L, -2);
    return 1;
}

/* ---------- req:fd() ---------- */
static int l_req_fd(lua_State *L) {
    req_handle_t *h = luaL_checkudata(L, 1, "http_curl_req");
    if (!h->req) {
        return luaL_error(L, "request 已结束");
    }
    lua_pushinteger(L, h->req->fd_read);
    return 1;
}

/* ---------- req:finish() -> true, {status,headers,body} | false, code, msg ---------- */
static int l_req_finish(lua_State *L) {
    req_handle_t *h = luaL_checkudata(L, 1, "http_curl_req");
    request_t *req = h->req;
    if (!req) {
        return luaL_error(L, "request 已结束");
    }

    char c;
    ssize_t n;
    do {
        n = read(req->fd_read, &c, 1);
    } while (n < 0 && errno == EINTR);

    close(req->fd_read);
    req->fd_read = -1;
    h->req = NULL;

    if (n != 1) {
        lua_pushboolean(L, 0);
        lua_pushinteger(L, (lua_Integer)CURLE_AGAIN);
        lua_pushstring(L, "未收到完成信号");
        req_release(req);
        return 3;
    }

    __atomic_thread_fence(__ATOMIC_ACQUIRE);

    if (req->rc == CURLE_OK) {
        lua_pushboolean(L, 1);
        lua_newtable(L);
        lua_pushinteger(L, (lua_Integer)req->status);
        lua_setfield(L, -2, "status");
        lua_pushlstring(L, req->header_buf.data ? req->header_buf.data : "",
                        req->header_buf.len);
        lua_setfield(L, -2, "headers");
        lua_pushlstring(L, req->body_buf.data ? req->body_buf.data : "",
                        req->body_buf.len);
        lua_setfield(L, -2, "body");
        req_release(req);
        return 2;
    } else {
        lua_pushboolean(L, 0);
        lua_pushinteger(L, (lua_Integer)req->rc);
        lua_pushstring(L, curl_easy_strerror(req->rc));
        req_release(req);
        return 3;
    }
}

static int req_gc(lua_State *L) {
    req_handle_t *h = lua_touserdata(L, 1);
    request_t *req = h->req;
    if (req) {
        if (req->fd_read != -1) {
            close(req->fd_read);
            req->fd_read = -1;
        }
        h->req = NULL;
        req_release(req);
    }
    return 0;
}

static const luaL_Reg req_methods[] = {
    { "fd", l_req_fd },
    { "finish", l_req_finish },
    { NULL, NULL },
};

static const luaL_Reg funcs[] = {
    { "start", l_start },
    { NULL, NULL },
};

int luaopen__http_curl(lua_State *L) {
    luaL_newmetatable(L, "http_curl_req");
    lua_pushcfunction(L, req_gc);
    lua_setfield(L, -2, "__gc");
    luaL_newlib(L, req_methods);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);

    luaL_newlib(L, funcs);
    return 1;
}
