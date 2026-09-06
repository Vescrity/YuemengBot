#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <string.h>

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#define REGEX_MT "regex_mt"

typedef struct {
    pcre2_code *code;
    pcre2_match_data *md;
} regex_t;

static regex_t *check_regex(lua_State *L, int idx)
{
    return (regex_t *)luaL_checkudata(L, idx, REGEX_MT);
}

static uint32_t parse_flags(lua_State *L, int idx)
{
    uint32_t options = 0;
    if (lua_type(L, idx) == LUA_TSTRING) {
        const char *flags = lua_tostring(L, idx);
        for (const char *f = flags; *f; f++) {
            switch (*f) {
                case 'i': options |= PCRE2_CASELESS; break;
                case 'm': options |= PCRE2_MULTILINE; break;
                case 's': options |= PCRE2_DOTALL; break;
                case 'x': options |= PCRE2_EXTENDED; break;
                case 'u': options |= PCRE2_UTF | PCRE2_UCP; break;
                default: break;
            }
        }
    }
    return options;
}

static void push_compile_error(lua_State *L, int errcode, PCRE2_SIZE erroffset)
{
    PCRE2_UCHAR msg[256];
    pcre2_get_error_message(errcode, msg, sizeof(msg));
    lua_pushnil(L);
    lua_pushfstring(L, "regex 编译失败 (offset %d): %s",
                    (int)erroffset, (const char *)msg);
}

static void push_match_result(lua_State *L, pcre2_match_data *md, int rc,
                              const char *subject)
{
    PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(md);
    uint32_t count = pcre2_get_ovector_count(md);
    uint32_t n = (uint32_t)rc;
    if (n > count) n = count;
    lua_createtable(L, (int)n, 0);
    for (uint32_t i = 0; i < n; i++) {
        PCRE2_SIZE s = ovector[2 * i];
        PCRE2_SIZE e = ovector[2 * i + 1];
        if (s == PCRE2_UNSET) {
            lua_pushnil(L);
        } else {
            lua_pushlstring(L, subject + s, (size_t)(e - s));
        }
        lua_rawseti(L, -2, (int)(i + 1));
    }
}

static int l_regex_new(lua_State *L)
{
    size_t plen;
    const char *pattern = luaL_checklstring(L, 1, &plen);
    uint32_t options = parse_flags(L, 2);

    int errcode = 0;
    PCRE2_SIZE erroffset = 0;
    pcre2_code *code = pcre2_compile((PCRE2_SPTR)pattern, (PCRE2_SIZE)plen,
                                     options, &errcode, &erroffset, NULL);
    if (!code) {
        push_compile_error(L, errcode, erroffset);
        return 2;
    }
    regex_t *re = (regex_t *)lua_newuserdata(L, sizeof(regex_t));
    re->code = code;
    re->md = pcre2_match_data_create_from_pattern(code, NULL);
    luaL_setmetatable(L, REGEX_MT);
    return 1;
}

static int l_regex_match(lua_State *L)
{
    regex_t *re = check_regex(L, 1);
    size_t len;
    const char *subject = luaL_checklstring(L, 2, &len);
    int rc = pcre2_match(re->code, (PCRE2_SPTR)subject, (PCRE2_SIZE)len,
                         0, 0, re->md, NULL);
    if (rc < 0) {
        if (rc == PCRE2_ERROR_NOMATCH) {
            lua_pushnil(L);
            return 1;
        }
        return luaL_error(L, "regex match 错误: %d", rc);
    }
    push_match_result(L, re->md, rc, subject);
    return 1;
}

static int l_regex_find(lua_State *L)
{
    regex_t *re = check_regex(L, 1);
    size_t len;
    const char *subject = luaL_checklstring(L, 2, &len);
    int rc = pcre2_match(re->code, (PCRE2_SPTR)subject, (PCRE2_SIZE)len,
                         0, 0, re->md, NULL);
    if (rc < 0) {
        if (rc == PCRE2_ERROR_NOMATCH) {
            lua_pushnil(L);
            return 1;
        }
        return luaL_error(L, "regex find 错误: %d", rc);
    }
    PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(re->md);
    lua_pushinteger(L, (lua_Integer)(ovector[0] + 1));
    lua_pushinteger(L, (lua_Integer)ovector[1]);
    return 2;
}

static int l_regex_gc(lua_State *L)
{
    regex_t *re = check_regex(L, 1);
    if (re->md) {
        pcre2_match_data_free(re->md);
        re->md = NULL;
    }
    if (re->code) {
        pcre2_code_free(re->code);
        re->code = NULL;
    }
    return 0;
}

static int l_regex_match_pattern(lua_State *L)
{
    size_t plen;
    const char *pattern = luaL_checklstring(L, 1, &plen);
    size_t slen;
    const char *subject = luaL_checklstring(L, 2, &slen);
    uint32_t options = parse_flags(L, 3);

    int errcode = 0;
    PCRE2_SIZE erroffset = 0;
    pcre2_code *code = pcre2_compile((PCRE2_SPTR)pattern, (PCRE2_SIZE)plen,
                                     options, &errcode, &erroffset, NULL);
    if (!code) {
        push_compile_error(L, errcode, erroffset);
        return 2;
    }
    pcre2_match_data *md = pcre2_match_data_create_from_pattern(code, NULL);
    int rc = pcre2_match(code, (PCRE2_SPTR)subject, (PCRE2_SIZE)slen,
                         0, 0, md, NULL);
    if (rc < 0) {
        pcre2_match_data_free(md);
        pcre2_code_free(code);
        if (rc == PCRE2_ERROR_NOMATCH) {
            lua_pushnil(L);
            return 1;
        }
        return luaL_error(L, "regex match 错误: %d", rc);
    }
    push_match_result(L, md, rc, subject);
    pcre2_match_data_free(md);
    pcre2_code_free(code);
    return 1;
}

static const luaL_Reg regex_methods[] = {
    { "match", l_regex_match },
    { "find", l_regex_find },
    { NULL, NULL },
};

static const luaL_Reg regex_funcs[] = {
    { "new", l_regex_new },
    { "match", l_regex_match_pattern },
    { NULL, NULL },
};

int luaopen_regex(lua_State *L)
{
    luaL_newmetatable(L, REGEX_MT);
    lua_pushcfunction(L, l_regex_gc);
    lua_setfield(L, -2, "__gc");
    luaL_newlib(L, regex_methods);
    lua_setfield(L, -2, "__index");
    luaL_newlib(L, regex_funcs);
    return 1;
}
