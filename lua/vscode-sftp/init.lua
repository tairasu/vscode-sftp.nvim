local M = {}

function M.setup()
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
