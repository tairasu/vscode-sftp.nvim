local M = {}
local Path = require('plenary.path')

-- Create mkdir commands for each directory in the path
function M.create_mkdir_commands(path)
  if path == '.' or path == '' then
    return ''
  end

  local parts = vim.split(path, '/', { plain = true })
  local commands = {}
  local current = ''

  for _, part in ipairs(parts) do
    if part ~= '' then
      current = (current == '') and part or current .. '/' .. part
      -- Use -mkdir to ignore errors if directory exists
      table.insert(commands, '-mkdir ' .. vim.fn.shellescape(current))
    end
  end

  return table.concat(commands, '\n')
end

-- Get remote path for a local file
function M.get_remote_path(conf, local_path)
  local workspace_root = vim.fn.getcwd()
  local relative_path = Path:new(local_path):make_relative(workspace_root)
  return Path:new(conf.remotePath):joinpath(relative_path).filename
end

-- Create SFTP batch command to download a file
function M.create_download_command(file)
  local remote_dir = vim.fn.fnamemodify(file, ':h')
  local local_path = file
  local cmd = ""

  -- Ensure local directory exists
  vim.fn.mkdir(vim.fn.fnamemodify(local_path, ':h'), 'p')

  if remote_dir == '.' or remote_dir == '' then
    cmd = string.format("get %s %s\n",
      vim.fn.shellescape(vim.fn.fnamemodify(file, ':t')),
      vim.fn.shellescape(local_path))
  else
    cmd = string.format("cd %s\nget %s %s\ncd ..\n",
      vim.fn.shellescape(remote_dir),
      vim.fn.shellescape(vim.fn.fnamemodify(file, ':t')),
      vim.fn.shellescape(local_path)
    )
  end
  return cmd
end

-- Create SFTP batch command to upload a file
function M.create_upload_command(file)
  local remote_dir = vim.fn.fnamemodify(file, ':h')
  local cmd = ''

  -- Create remote directories if needed
  if remote_dir ~= '.' then
    cmd = M.create_mkdir_commands(remote_dir) .. '\n'
  end

  if remote_dir == '.' then
    cmd = cmd .. string.format('put %s\n',
      vim.fn.shellescape(file)
    )
  else
    cmd = cmd .. string.format('cd %s\nput %s %s\ncd ..\n',
      vim.fn.shellescape(remote_dir),
      vim.fn.shellescape(file),
      vim.fn.shellescape(vim.fn.fnamemodify(file, ':t'))
    )
  end
  return cmd
end

-- Check if a file should be ignored based on patterns
function M.should_ignore(file, ignore_patterns)
  if not ignore_patterns then
    return false
  end

  for _, pattern in ipairs(ignore_patterns) do
    -- Convert glob pattern to Lua pattern
    pattern = pattern:gsub("%.", "%%.")
                    :gsub("%*", ".*")
                    :gsub("%?", ".")
    if file:match(pattern) then
      return true
    end
  end
  return false
end

-- Get all files in directory recursively
function M.get_all_files(dir, ignore_patterns)
  local files = {}
  local handle = vim.loop.fs_scandir(dir)
  
  while handle do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end

    local path = dir .. '/' .. name
    local relative_path = Path:new(path):make_relative(vim.fn.getcwd())

    if not M.should_ignore(relative_path, ignore_patterns) then
      if type == 'file' then
        table.insert(files, relative_path)
      elseif type == 'directory' then
        local subfiles = M.get_all_files(path, ignore_patterns)
        vim.list_extend(files, subfiles)
      end
    end
  end

  return files
end

-- Compare two paths for equality (normalizing separators)
function M.paths_equal(path1, path2)
  path1 = path1:gsub("\\", "/")
  path2 = path2:gsub("\\", "/")
  return path1 == path2
end

-- Get file modification time safely
function M.get_mtime(path)
  local mtime = vim.fn.getftime(path)
  return mtime == -1 and 0 or mtime
end

-- Get file size safely
function M.get_size(path)
  local size = vim.fn.getfsize(path)
  return size == -1 and 0 or size
end

-- Create a temporary file with cleanup
function M.with_temp_file(callback)
  local temp_file = vim.fn.tempname()
  local success, result = pcall(callback, temp_file)
  -- Clean up temp file
  pcall(vim.fn.delete, temp_file)
  if not success then
    error(result)
  end
  return result
end

-- Ensure directory exists
function M.ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, 'p')
  end
end

-- Get parent directory
function M.get_parent_dir(path)
  return vim.fn.fnamemodify(path, ':h')
end

-- Get filename from path
function M.get_filename(path)
  return vim.fn.fnamemodify(path, ':t')
end

-- Check if path is absolute
function M.is_absolute_path(path)
  return path:match('^/') or path:match('^%a:[\\/]')
end

-- Convert path to use forward slashes
function M.normalize_path(path)
  return path:gsub('\\', '/')
end

return M 