local M = {}
local commands = require('vscode-sftp.commands')
local config = require('vscode-sftp.config')
local ui = require('vscode-sftp.ui')

-- Default configuration
local default_config = {
  debug = false,
  upload_on_save = false,
  ignore_filetypes = { -- Filetypes to ignore on auto-upload
    "gitcommit",
    "gitrebase",
  },
  ignore = { -- Global ignore patterns
    ".git",
    ".DS_Store",
    "node_modules",
    ".vscode"
  }
}

-- Setup function to initialize the plugin
function M.setup(opts)
  -- Merge user config with defaults
  opts = vim.tbl_deep_extend('force', default_config, opts or {})
  
  -- Initialize configuration
  config.setup(opts)

  -- Create autocommand group for SFTP
  local group = vim.api.nvim_create_augroup("VSCodeSFTP", { clear = true })

  -- Add BufWritePost autocommand to check uploadOnSave
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function()
      local conf = config.find_config()
      if conf and conf.uploadOnSave then
        commands.upload_current_file()
      end
    end,
  })

  -- Create user commands
  vim.api.nvim_create_user_command('SFTPUpload', function()
    local conf = config.find_config()
    if not conf then
      ui.show_error('No sftp.json configuration found')
      return
    end
    commands.upload_current_file()
  end, {})

  vim.api.nvim_create_user_command('SFTPDownload', function()
    local conf = config.find_config()
    if not conf then
      ui.show_error('No sftp.json configuration found')
      return
    end
    commands.download_current_file()
  end, {})

  vim.api.nvim_create_user_command('SFTPSync', function()
    local conf = config.find_config()
    if not conf then
      ui.show_error('No sftp.json configuration found')
      return
    end
    commands.sync_project()
  end, {})

  vim.api.nvim_create_user_command('SFTPDownloadDir', function()
    local conf = config.find_config()
    if not conf then
      ui.show_error('No sftp.json configuration found')
      return
    end
    commands.download_directory()
  end, {})

  vim.api.nvim_create_user_command('SFTPUploadDir', function()
    local conf = config.find_config()
    if not conf then
      ui.show_error('No sftp.json configuration found')
      return
    end
    commands.upload_directory()
  end, {})

  vim.api.nvim_create_user_command('SFTPInit', function()
    -- Create .vscode directory if it doesn't exist
    local vscode_dir = '.vscode'
    if vim.fn.isdirectory(vscode_dir) == 0 then
      vim.fn.mkdir(vscode_dir, 'p')
    end

    -- Check if config already exists
    local config_path = vscode_dir .. '/sftp.json'
    if vim.fn.filereadable(config_path) == 1 then
      ui.show_warning('sftp.json already exists!')
      return
    end

    -- Create template configuration
    local template = {
      name = "My Server",
      host = "hostname",
      protocol = "sftp",
      port = 22,
      username = "username",
      remotePath = "/path/to/remote/project",
      uploadOnSave = true,
      ignore = vim.deepcopy(opts.ignore)
    }

    -- Write configuration file
    local f = io.open(config_path, 'w')
    if not f then
      ui.show_error('Failed to create sftp.json')
      return
    end

    f:write(vim.fn.json_encode(template))
    f:close()

    ui.show_success('Created sftp.json template')
  end, {})

  vim.api.nvim_create_user_command('SFTPDelete', function()
    local conf = config.find_config()
    if not conf then
      ui.show_error('No sftp.json configuration found')
      return
    end
    commands.delete_remote()
  end, {})

  -- Set up autocommands for upload on save
  if opts.upload_on_save then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = vim.api.nvim_create_augroup("SFTPAutoUpload", { clear = true }),
      callback = function()
        local conf = config.find_config()
        if not conf or not conf.uploadOnSave then
          return
        end

        -- Check filetype exclusions
        local ft = vim.bo.filetype
        for _, ignored_ft in ipairs(opts.ignore_filetypes) do
          if ft == ignored_ft then
            return
          end
        end

        commands.upload_current_file()
      end,
    })
  end

  -- Watch for config file changes
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("SFTPConfigWatch", { clear = true }),
    pattern = "**/.vscode/sftp.json",
    callback = function()
      config.clear_cache()
      ui.show_info("SFTP configuration reloaded")
    end,
  })
end

-- Helper function to test SFTP connection
function M.test_connection()
  local conf = config.find_config()
  if not conf then
    ui.show_error('No sftp.json configuration found')
    return
  end

  local sftp = require('vscode-sftp.sftp_client')
  sftp.test_connection(conf, function(success, message)
    if success then
      ui.show_success(message)
    else
      ui.show_error(message)
    end
  end)
end

return M