local M = {}
local Path = require('plenary.path')
local config = require('vscode-sftp.config')
local sftp = require('vscode-sftp.sftp_client')
local ui = require('vscode-sftp.ui')
local utils = require('vscode-sftp.utils')

-- Upload current file to remote
function M.upload_current_file()
  local conf = config.find_config()
  if not conf then
    ui.show_error('No SFTP configuration found')
    return
  end

  local current_file = vim.fn.expand('%:p')
  local relative_path = Path:new(current_file):make_relative(vim.fn.getcwd())
  local remote_dir = vim.fn.fnamemodify(relative_path, ':h')
  
  -- Create batch command
  local batch_cmd = ''
  if remote_dir ~= '.' then
    batch_cmd = utils.create_mkdir_commands(remote_dir) .. '\n'
  end

  if remote_dir == '.' then
    batch_cmd = batch_cmd .. string.format('put %s\n',
      vim.fn.shellescape(current_file)
    )
  else
    batch_cmd = batch_cmd .. string.format('put %s %s/%s\n',
      vim.fn.shellescape(current_file),
      vim.fn.shellescape(remote_dir),
      vim.fn.shellescape(vim.fn.fnamemodify(current_file, ':t'))
    )
  end

  sftp.execute_command(conf, batch_cmd, function(success, output)
    if success then
      ui.show_success(string.format('Uploaded %s', current_file))
    else
      ui.show_error(string.format('Failed to upload %s: %s', current_file, table.concat(output, '\n')))
    end
  end)
end

-- Download current file from remote
function M.download_current_file()
  local conf = config.find_config()
  if not conf then
    ui.show_error('No SFTP configuration found')
    return
  end

  local current_file = vim.fn.expand('%:p')
  local current_dir = vim.fn.fnamemodify(current_file, ':h')
  local relative_dir = Path:new(current_dir):make_relative(vim.fn.getcwd())

  sftp.get_remote_listing(conf, function(remote_listing)
    if not remote_listing then
      ui.show_error("Failed to retrieve remote file list")
      return
    end

    local available_files = {}
    for remote_file, info in pairs(remote_listing) do
      if remote_file:sub(1, #conf.remotePath + 1) == conf.remotePath .. "/" then
        local relative_file = remote_file:sub(#conf.remotePath + 2)
        local file_dir = vim.fn.fnamemodify(relative_file, ':h')
        if file_dir == relative_dir or (file_dir == '.' and relative_dir == '') then
          table.insert(available_files, {
            name = vim.fn.fnamemodify(relative_file, ':t'),
            path = relative_file,
            info = info,
            local_mtime = vim.fn.getftime(relative_file),
            local_size = vim.fn.getfsize(relative_file)
          })
        end
      end
    end

    if #available_files == 0 then
      ui.show_error("No files found in remote directory")
      return
    end

    table.sort(available_files, function(a, b) return a.name < b.name end)

    local items = {}
    for _, file in ipairs(available_files) do
      table.insert(items, ui.format_list_item(file))
    end

    vim.ui.select(items, ui.create_select_opts("Select file to download:"), function(_, idx)
      if not idx then
        ui.show_info("Download cancelled")
        return
      end

      local file = available_files[idx]
      local local_path = file.path

      vim.fn.mkdir(vim.fn.fnamemodify(local_path, ':h'), 'p')
      local batch_cmd = utils.create_download_command(file.path)

      sftp.execute_command(conf, batch_cmd, function(success, output)
        if success then
          ui.show_success(string.format('Downloaded %s', file.path))
          if file.path == vim.fn.expand('%:p') then
            vim.cmd('e!')
          end
        else
          ui.show_error(string.format('Failed to download %s: %s', file.path, table.concat(output, '\n')))
        end
      end)
    end)
  end)
end

-- Download all files in current directory
function M.download_directory()
  local conf = config.find_config()
  if not conf then
    ui.show_error('No SFTP configuration found')
    return
  end

  local current_file = vim.fn.expand('%:p')
  local current_dir = vim.fn.fnamemodify(current_file, ':h')
  local relative_dir = Path:new(current_dir):make_relative(vim.fn.getcwd())

  sftp.get_remote_listing(conf, function(remote_listing)
    if not remote_listing then
      ui.show_error("Failed to retrieve remote file list")
      return
    end

    local files_to_download = {}
    local total_download_size = 0

    for remote_file, info in pairs(remote_listing) do
      if remote_file:sub(1, #conf.remotePath + 1) == conf.remotePath .. "/" then
        local relative_file = remote_file:sub(#conf.remotePath + 2)
        local file_dir = vim.fn.fnamemodify(relative_file, ':h')
        if file_dir == relative_dir or (file_dir == '.' and relative_dir == '') then
          local local_path = relative_file
          local local_mtime = vim.fn.getftime(local_path)
          local local_size = vim.fn.getfsize(local_path)
          if local_mtime == -1 or local_mtime < info.mtime then
            table.insert(files_to_download, {
              name = vim.fn.fnamemodify(relative_file, ':t'),
              remote_file = relative_file,
              local_path = local_path,
              info = info,
              local_mtime = local_mtime == -1 and 0 or local_mtime,
              local_size = local_size == -1 and 0 or local_size
            })
            total_download_size = total_download_size + info.size
          end
        end
      end
    end

    if #files_to_download == 0 then
      ui.show_info("No files to download in current directory")
      return
    end

    table.sort(files_to_download, function(a, b) return a.name < b.name end)

    -- Show file list for review
    local items = {}
    for _, file in ipairs(files_to_download) do
      table.insert(items, ui.format_list_item(file))
    end

    local header = ui.create_summary_header(#files_to_download, total_download_size)
    
    vim.ui.select(items, ui.create_select_opts(header), function(_, _)
      -- After showing the list, ask for confirmation
      vim.ui.select({'Yes', 'No'}, {
        prompt = ui.format_confirmation_prompt(#files_to_download),
        default = 'No'
      }, function(choice)
        if choice ~= 'Yes' then
          ui.show_info("Download cancelled")
          return
        end

        for _, file in ipairs(files_to_download) do
          local batch_cmd = utils.create_download_command(file.remote_file)
          sftp.execute_command(conf, batch_cmd, function(success, output)
            if success then
              ui.show_success(string.format('Downloaded %s', file.remote_file))
              if file.remote_file == vim.fn.expand('%:p') then
                vim.cmd('e!')
              end
            else
              ui.show_error(string.format('Failed to download %s: %s', 
                file.remote_file, table.concat(output, '\n')))
            end
          end)
        end
      end)
    end)
  end)
end

-- Upload all files in current directory
function M.upload_directory()
  local conf = config.find_config()
  if not conf then
    ui.show_error('No SFTP configuration found')
    return
  end

  local current_file = vim.fn.expand('%:p')
  local current_dir = vim.fn.fnamemodify(current_file, ':h')
  local relative_dir = Path:new(current_dir):make_relative(vim.fn.getcwd())

  local local_files = vim.fn.systemlist(string.format("find '%s' -type f -maxdepth 1", current_dir))
  if #local_files == 0 then
    ui.show_info("No files found in current directory")
    return
  end

  sftp.get_remote_listing(conf, function(remote_listing)
    if not remote_listing then
      ui.show_error("Failed to retrieve remote file list")
      return
    end

    local files_to_upload = {}
    local total_upload_size = 0

    for _, local_path in ipairs(local_files) do
      local relative_path = Path:new(local_path):make_relative(vim.fn.getcwd())
      local remote_key = conf.remotePath .. "/" .. relative_path
      local local_mtime = vim.fn.getftime(local_path)
      local local_size = vim.fn.getfsize(local_path)
      local remote_info = remote_listing[remote_key]

      if not remote_info or local_mtime > remote_info.mtime then
        table.insert(files_to_upload, {
          name = vim.fn.fnamemodify(local_path, ':t'),
          local_path = local_path,
          relative_path = relative_path,
          local_mtime = local_mtime,
          local_size = local_size,
          info = remote_info or { mtime = 0, size = 0 }
        })
        total_upload_size = total_upload_size + local_size
      end
    end

    if #files_to_upload == 0 then
      ui.show_info("No files to upload in current directory")
      return
    end

    -- Show file list for review
    local items = {}
    for _, file in ipairs(files_to_upload) do
      table.insert(items, ui.format_list_item(file))
    end

    local header = ui.create_summary_header(#files_to_upload, total_upload_size)

    vim.ui.select(items, ui.create_select_opts(header), function(_, _)
      vim.ui.select({'Yes', 'No'}, {
        prompt = ui.format_confirmation_prompt(#files_to_upload),
        default = 'No'
      }, function(choice)
        if choice ~= 'Yes' then
          ui.show_info("Upload cancelled")
          return
        end

        for _, file in ipairs(files_to_upload) do
          local batch_cmd = utils.create_upload_command(file.relative_path)
          sftp.execute_command(conf, batch_cmd, function(success, output)
            if success then
              ui.show_success(string.format('Uploaded %s', file.relative_path))
            else
              ui.show_error(string.format('Failed to upload %s: %s',
                file.relative_path, table.concat(output, '\n')))
            end
          end)
        end
      end)
    end)
  end)
end

-- Delete remote and local file
function M.delete_remote()
  local conf = config.find_config()
  if not conf then
    ui.show_error('No SFTP configuration found')
    return
  end

  local current_dir = vim.fn.expand('%:p:h')
  -- Get all files in current directory
  local local_files = vim.fn.systemlist(string.format("find '%s' -type f -maxdepth 1", current_dir))
  
  if #local_files == 0 then
    ui.show_info("No files found in current directory")
    return
  end

  -- Format files for selection
  local items = {}
  for _, file_path in ipairs(local_files) do
    local file = {
      name = vim.fn.fnamemodify(file_path, ':t'),
      path = file_path,
      relative_path = Path:new(file_path):make_relative(vim.fn.getcwd()),
      local_mtime = vim.fn.getftime(file_path),
      local_size = vim.fn.getfsize(file_path),
      info = {
        mtime = vim.fn.getftime(file_path),
        size = vim.fn.getfsize(file_path)
      }
    }
    table.insert(items, ui.format_list_item(file))
  end

  -- Show file selection dialog
  vim.ui.select(items, ui.create_select_opts("Select file to delete:"), function(_, idx)
    if not idx then
      ui.show_info("Delete cancelled")
      return
    end

    local file = local_files[idx]
    local relative_path = Path:new(file):make_relative(vim.fn.getcwd())

    -- Show confirmation dialog
    vim.ui.select({'Yes', 'No'}, {
      prompt = string.format("Are you sure you want to delete '%s' (locally and remotely)?", relative_path),
      default = 'No'
    }, function(choice)
      if choice ~= 'Yes' then
        ui.show_info("Delete cancelled")
        return
      end

      -- Delete remote file
      local remote_dir = vim.fn.fnamemodify(relative_path, ':h')
      local batch_cmd = string.format('cd %s\nrm %s\n',
        vim.fn.shellescape(remote_dir),
        vim.fn.shellescape(vim.fn.fnamemodify(file, ':t'))
      )

      sftp.execute_command(conf, batch_cmd, function(success, output)
        if success then
          -- Delete local file
          local ok, err = os.remove(file)
          if ok then
            ui.show_success(string.format('Deleted %s (locally and remotely)', relative_path))
            -- Reload buffer if currently open
            if vim.fn.expand('%:p') == file then
              vim.cmd('e!')
            end
          else
            ui.show_error(string.format('Failed to delete local file %s: %s', relative_path, err))
          end
        else
          ui.show_error(string.format('Failed to delete remote file %s: %s', 
            relative_path, table.concat(output, '\n')))
        end
      end)
    end)
  end)
end

-- Sync entire project
function M.sync_project()
  -- Implementation moved to a separate sync.lua module for better organization
  require('vscode-sftp.sync').sync_project()
end

return M