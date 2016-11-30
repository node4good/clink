-- Copyright (c) 2012 Martin Ridgers
-- License: http://opensource.org/licenses/MIT

--------------------------------------------------------------------------------
local function warn(msg)
    print("WARNING: " .. msg)
end

--------------------------------------------------------------------------------
local function exec(cmd, silent)
    print("## EXEC: " .. cmd)

    if silent then
        cmd = "1>nul 2>nul "..cmd
    end

    -- Premake replaces os.execute() with a version that runs path.normalize()
    -- which converts \ to /. This is fine for everything except cmd.exe.
    local prev_norm = path.normalize
    path.normalize = function (x) return x end
    ret = os.execute(cmd)
    path.normalize = prev_norm

    return ret
end

--------------------------------------------------------------------------------
local function mkdir(dir)
    if os.isdir(dir) then
        return
    end

    local ret = exec("md " .. path.translate(dir), true)
    if ret ~= 0 then
        error("Failed to create directory '" .. dir .. "'")
    end
end

--------------------------------------------------------------------------------
local function rmdir(dir)
    if not os.isdir(dir) then
        return
    end

    return exec("rd /q /s " .. path.translate(dir), true)
end

--------------------------------------------------------------------------------
local function unlink(file)
    return exec("del /q " .. path.translate(file), true)
end

--------------------------------------------------------------------------------
local function copy(src, dest)
    src = path.translate(src)
    dest = path.translate(dest)
    return exec("copy /y " .. src .. " " .. dest, true)
end

--------------------------------------------------------------------------------
local function have_required_tool(name)
    return (exec("where " .. name, true) == 0)
end

--------------------------------------------------------------------------------
local function get_target_dir()
    local target_dir = ".build/release/"
    target_dir = target_dir .. os.date("%Y%m%d_")
    target_dir = target_dir .. get_last_git_commit()
    if clink_ver ~= "DEV" then
        target_dir = target_dir .. "_" .. clink_ver
    end

    target_dir = path.getabsolute(target_dir) .. "/"
    if not os.isdir(target_dir .. ".") then
        rmdir(target_dir)
        mkdir(target_dir)
    end

    return target_dir
end

--------------------------------------------------------------------------------
newaction {
    trigger = "release",
    description = "Creates a release of Clink.",
    execute = function ()
        local premake = _PREMAKE_COMMAND
        local target_dir = get_target_dir()

        -- Check we have the tools we need.
        local have_msbuild = have_required_tool("msbuild")
        local have_mingw = have_required_tool("mingw32-make")
        local have_nsis = have_required_tool("makensis")
        local have_7z = have_required_tool("7z")

        -- Clone repro in release folder and checkout the specified version
        local repo_path = "clink_" .. clink_ver .. "_src"
        local code_dir = target_dir .. repo_path
        rmdir(code_dir)
        mkdir(code_dir)

        exec("git clone . " .. code_dir)
        if not os.chdir(code_dir) then
            print("Failed to chdir to '" .. code_dir .. "'")
            return
        end
        exec("git checkout " .. (_OPTIONS["commit"] or "HEAD"))

        local src_dir_name = path.getabsolute(".")

        -- Update embedded Lua scripts.
        exec(premake .. " embed")

        -- Build the code.
        local x86_ok = true;
        local x64_ok = true;
        local toolchain = "ERROR"
        if have_msbuild then
            toolchain = _OPTIONS["vsver"] or "vs2013"
            exec(premake .. " --clink_ver=" .. clink_ver .. " " .. toolchain)

            ret = exec("msbuild /m /v:q /p:configuration=final /p:platform=win32 .build/" .. toolchain .. "/clink.sln")
            if ret ~= 0 then
                x86_ok = false
            end

            ret = exec("msbuild /m /v:q /p:configuration=final /p:platform=x64 .build/" .. toolchain .. "/clink.sln")
            if ret ~= 0 then
                x64_ok = false
            end
        elseif have_mingw then
            toolchain = "gmake"
            exec(premake .. " --clink_ver=" .. clink_ver .. " gmake")
            os.chdir(".build/gmake")

            local ret
            ret = exec("1>nul mingw32-make CC=gcc config=final_x32 -j%number_of_processors%")
            if ret ~= 0 then
                x86_ok = false
            end

            ret = exec("1>nul mingw32-make CC=gcc config=final_x64 -j%number_of_processors%")
            if ret ~= 0 then
                x64_ok = false
            end

            os.chdir("../..")
        else
            error("Unable to locate either msbuild.exe or mingw32-make.exe")
        end

        local src = ".build/" .. toolchain .. "/bin/final/"
        local dest = target_dir .. "clink_" .. clink_ver

        -- Do a coarse check to make sure there's a build available.
        if not os.isdir(src .. ".") or not (x86_ok or x64_ok) then
            print("There's no build available in '" .. src .. "'")
            return
        end

        -- Copy release files to a directory.
        rmdir(dest)
        mkdir(dest)

        local manifest = {
            "clink.bat",
            "clink_x*.exe",
            "clink*.dll",
            "CHANGES",
            "LICENSE",
            "clink_dll_x*.pdb",
        }

        for _, mask in ipairs(manifest) do
            copy(src .. mask, dest)
        end

        -- Generate documentation.
        exec(premake .. " --clink_ver=" .. clink_ver .. " clink_docs")
        copy(".build/docs/clink.html", dest)

        -- Build the installer.
        if have_nsis then
            local nsis_cmd = "makensis"
            nsis_cmd = nsis_cmd .. " /DCLINK_BUILD=" .. dest
            nsis_cmd = nsis_cmd .. " /DCLINK_VERSION=" .. clink_ver
            nsis_cmd = nsis_cmd .. " /DCLINK_SOURCE=" .. src_dir_name
            nsis_cmd = nsis_cmd .. " " .. src_dir_name .. "/installer/clink.nsi"
            exec(nsis_cmd)
        end

        -- Tidy up code directory.
        rmdir(".build")
        rmdir(".git")
        unlink(".gitignore")

        -- Zip up the source code.
        os.chdir(target_dir)
        if have_7z then
            exec("7z a -r " .. target_dir .. "clink_" .. clink_ver .. "_src.zip " .. src_dir_name)
        end
        rmdir(src_dir_name)

        -- Move PDBs out of the way and zip them up.
        os.chdir(dest)
        if have_msbuild then
            exec("move *.pdb  .. ")
            if have_7z then
                exec("7z a -r  ../clink_" .. clink_ver .. "_pdb.zip  ../*.pdb")
                unlink("../*.pdb")
            end
        end

        -- Package the release in an archive.
        if have_7z then
            exec("7z a -r  ../clink_" .. clink_ver .. ".zip  ../clink_" .. clink_ver)
        end

        -- Report some facts about what just happened.
        print("\n\n")
        if not have_7z then     warn("7-ZIP NOT FOUND     -- Packing to .zip files was skipped.") end
        if not have_nsis then   warn("NSIS NOT FOUND      -- No installer was not created.") end
        if not x86_ok then      warn("x86 BUILD FAILED") end
        if not x64_ok then      warn("x64 BUILD FAILED") end
    end
}

--------------------------------------------------------------------------------
newoption {
   trigger     = "vsver",
   value       = "VER",
   description = "Version of Visual Studio to build release with"
}

--------------------------------------------------------------------------------
newoption {
   trigger     = "commit",
   value       = "SPEC",
   description = "Git commit/tag to build Clink release from"
}
