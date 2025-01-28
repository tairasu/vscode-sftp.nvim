local M = {}

-- Default configuration
M.config = {
    auto_upload = true,  -- Global setting to enable/disable auto upload
    debug = false,
}

-- Helper function to check if a file should be ignored
local function should_ignore_file(file_path, ignore_patterns)
    if not ignore_patterns then
        return false
    end
    
    for _, pattern in ipairs(ignore_patterns) do
        -- Convert glob pattern to Lua pattern
        local lua_pattern = pattern:gsub("%.", "%%.")  -- Escape dots
                                 :gsub("%*", ".*")     -- Convert * to .*
                                 :gsub("%?", ".")      -- Convert ? to .
        if file_path:match(lua_pattern) then
            return true
        end
    end
    return false
end

-- Setup function to initialize the plugin
function M.setup(opts)
    -- Merge user config with defaults
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})

    -- Create the plugin augroup
    local group = vim.api.nvim_create_augroup('VscodeSFTP', { clear = true })

    -- Initialize components
    local config = require('vscode-sftp.config')
    local sftp = require('vscode-sftp.sftp')

    -- Setup auto upload on save
    vim.api.nvim_create_autocmd('BufWritePost', {
        group = group,
        pattern = '*',
        callback = function()
            -- Check if auto upload is enabled globally
            if not M.config.auto_upload then
                return
            end
            
            -- Get SFTP config for current file
            local conf = config.find_config()
            if not conf then
                return
            end
            
            -- Check if uploadOnSave is enabled in the config
            if conf.uploadOnSave == false then
                return
            end
            
            -- Get the current file path
            local current_file = vim.fn.expand('%:p')
            local relative_path = vim.fn.fnamemodify(current_file, ':.:')
            
            -- Check if file is in ignore list
            if should_ignore_file(relative_path, conf.ignore) then
                if M.config.debug then
                    vim.notify(string.format('Skipping ignored file: %s', relative_path), vim.log.levels.DEBUG)
                end
                return
            end
            
            -- Upload the file
            sftp.upload_current_file()
        end
    })

    -- Create user commands
    vim.api.nvim_create_user_command('SFTPUpload', function()
        local conf = config.find_config()
        if not conf then
            vim.notify('No sftp.json configuration found', vim.log.levels.ERROR)
            return
        end
        sftp.upload_current_file()
    end, {})
    
    vim.api.nvim_create_user_command('SFTPDownload', function()
        local conf = config.find_config()
        if not conf then
            vim.notify('No sftp.json configuration found', vim.log.levels.ERROR)
            return
        end
        sftp.download_current_file()
    end, {})
    
    vim.api.nvim_create_user_command('SFTPSync', function()
        local conf = config.find_config()
        if not conf then
            vim.notify('No sftp.json configuration found', vim.log.levels.ERROR)
            return
        end
        sftp.sync_project()
    end, {})
    
    vim.api.nvim_create_user_command('SFTPInit', function()
        -- Create .vscode directory if it doesn't exist
        local vscode_dir = '.vscode'
        if vim.fn.isdirectory(vscode_dir) == 0 then
            vim.fn.mkdir(vscode_dir, 'p')
        end
        
        -- Write the template to sftp.json
        local config_path = vscode_dir .. '/sftp.json'
        if vim.fn.filereadable(config_path) == 1 then
            vim.notify('sftp.json already exists!', vim.log.levels.WARN)
            return
        end
        
        local template = {
            name = "My Server",
            host = "hostname",
            protocol = "sftp",
            port = 22,
            username = "username",
            remotePath = "/path/to/remote/project",
            uploadOnSave = true,
            ignore = {
                ".vscode",
                ".git",
                ".DS_Store",
                "node_modules",
                "dist"
            }
        }
        
        local f = io.open(config_path, 'w')
        if not f then
            vim.notify('Failed to create sftp.json', vim.log.levels.ERROR)
            return
        end
        
        f:write(vim.fn.json_encode(template))
        f:close()
        
        vim.notify('Created sftp.json template', vim.log.levels.INFO)
    end, {})
    
    vim.api.nvim_create_user_command('SFTPDelete', function()
        local conf = config.find_config()
        if not conf then
            vim.notify('No sftp.json configuration found', vim.log.levels.ERROR)
            return
        end
        sftp.delete_remote()
    end, {})

    -- Setup config watcher
    vim.api.nvim_create_autocmd({"BufWritePost"}, {
        group = group,
        pattern = "**/.vscode/sftp.json",
        callback = function()
            config.clear_cache()
        end
    })
end

return M
