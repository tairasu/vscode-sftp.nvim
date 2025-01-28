local M = {}

-- Default configuration
M.config = {
    auto_upload = true,
    debug = false,
}

-- Add module loading verification
local function verify_modules()
  local modules = {
    "vscode-sftp.config",
    "vscode-sftp.sftp",
    "plenary.async"
  }
  
  for _, module in ipairs(modules) do
    local ok, _ = pcall(require, module)
    if not ok then
      return false, "Failed to load module: " .. module
    end
  end
  return true
end

-- Setup function to initialize the plugin
function M.setup(opts)
    -- Merge user config with defaults
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})

    -- Load plugin components
    require('vscode-sftp.config').setup()
    require('vscode-sftp.commands').setup()
    require('vscode-sftp.autocmds').setup()

    -- Verify all required modules are loaded
    local modules_ok, err = verify_modules()
    if not modules_ok then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    local ok, err = pcall(function()
      vim.notify("vscode-sftp.nvim loaded successfully!", vim.log.levels.INFO)
      
      -- Initialize the autocmd for upload on save
      vim.api.nvim_create_autocmd("BufWritePost", {
        pattern = "*",
        callback = function()
          -- Only upload if config exists
          if require("vscode-sftp.config").find_config() then
            require("vscode-sftp.sftp").upload_current_file()
          end
        end,
      })

      -- Add commands
      vim.api.nvim_create_user_command("SFTPUpload", function()
        require("vscode-sftp.sftp").upload_current_file()
      end, {})

      vim.api.nvim_create_user_command("SFTPDownload", function()
        require("vscode-sftp.sftp").download_file()
      end, {})
    end)
    
    if not ok then
      vim.notify("Failed to setup vscode-sftp.nvim: " .. tostring(err), vim.log.levels.ERROR)
    end
end

return M
