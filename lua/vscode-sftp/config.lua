local M = {}

-- Default configuration schema
local default_config = {
    name = "",
    host = "",
    protocol = "sftp",
    port = 22,
    username = "",
    password = "",
    privateKeyPath = "",
    remotePath = "",
    uploadOnSave = true,
    ignore = {
        ".vscode",
        ".git",
        ".DS_Store"
    }
}

-- Cache for loaded configurations
local config_cache = {}

-- Clear the configuration cache
function M.clear_cache()
    config_cache = {}
end

-- Validate configuration
local function validate_config(config)
    if not config.host or config.host == "" then
        return false, "Host is required"
    end
    if not config.username or config.username == "" then
        return false, "Username is required"
    end
    if not config.remotePath or config.remotePath == "" then
        return false, "Remote path is required"
    end
    -- Password or private key must be provided
    if (not config.password or config.password == "") and
       (not config.privateKeyPath or config.privateKeyPath == "") then
        return false, "Either password or privateKeyPath must be provided"
    end
    return true
end

-- Find and parse sftp.json in the .vscode directory
function M.find_config()
    local current_file = vim.fn.expand('%:p')
    local current_dir = vim.fn.fnamemodify(current_file, ':h')
    
    -- Check cache first
    if config_cache[current_dir] then
        return config_cache[current_dir]
    end
    
    -- Search for .vscode/sftp.json in current and parent directories
    local config_path = nil
    local dir = current_dir
    while dir ~= '/' do
        local test_path = dir .. '/.vscode/sftp.json'
        if vim.fn.filereadable(test_path) == 1 then
            config_path = test_path
            break
        end
        dir = vim.fn.fnamemodify(dir, ':h')
    end
    
    if not config_path then
        return nil
    end
    
    -- Read and parse config file
    local config_content = vim.fn.readfile(config_path)
    local ok, config = pcall(vim.fn.json_decode, table.concat(config_content, '\n'))
    if not ok then
        vim.notify('Failed to parse sftp.json: ' .. config, vim.log.levels.ERROR)
        return nil
    end
    
    -- Merge with defaults
    config = vim.tbl_deep_extend('keep', config, default_config)
    
    -- Validate config
    local valid, err = validate_config(config)
    if not valid then
        vim.notify('Invalid sftp.json configuration: ' .. err, vim.log.levels.ERROR)
        return nil
    end
    
    -- Cache the config
    config_cache[current_dir] = config
    return config
end

-- Initialize configuration
function M.setup()
    -- Clear cache when configuration might have changed
    vim.api.nvim_create_autocmd({"BufWritePost"}, {
        pattern = "**/.vscode/sftp.json",
        callback = function()
            config_cache = {}
        end
    })
end

return M
