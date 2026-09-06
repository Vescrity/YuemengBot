local platforms = {
    _list = {},
}

function platforms.add(platform)
    platforms._list[#platforms._list + 1] = platform
end

function platforms.remove(platform)
    local list = platforms._list
    for i = #list, 1, -1 do
        if list[i] == platform then
            table.remove(list, i)
            return
        end
    end
end

function platforms.list()
    return platforms._list
end

return platforms
