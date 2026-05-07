#!/usr/bin/env luajit

local modules_dir = arg[1] or 'modules'
local ramfs_header = arg[2] or 'bin_ramfs_luac.h'
local initrd_header = arg[3] or 'bin_initrd_tar.h'
local strip_level = tonumber(arg[4]) or 1

package.path = modules_dir .. '/?.lua;' .. modules_dir .. '/?/init.lua;' .. package.path

local ramfs = require('runtime.ramfs')


local r = ramfs.mkramfs(modules_dir .. '/runtime/ramfs.lua', ramfs_header)
assert(r)

local dirs = {
    {
        path = modules_dir,
        level = strip_level
    }
}
local r = ramfs.mkinitrd(initrd_header, dirs)
assert(r)
