local M = {}
local Job = require('plenary.job')
local ui = require('vscode-sftp.ui')
local Path = require('plenary.path')
local utils = require('vscode-sftp.utils')

-- Create SFTP batch commands with authentication options
local function create_sftp_commands(conf)
  local commands = {}

  -- Add SSH key if specified
  if conf.privateKeyPath then
    local key_path = vim.fn.expand(conf.privateKeyPath)
    if vim.fn.filereadable(key_path) == 0 then
      error("SSH key file not found: " .. key_path)
    end

    table.insert(commands, "-i")
    table.insert(commands, key_path)
    table.insert(commands, "-o")
    table.insert(commands, "StrictHostKeyChecking=no")
  end

  -- Add custom port if not default
  if conf.port ~= 22 then
    table.insert(commands, "-P")
    table.insert(commands, tostring(conf.port))
  end

  -- Add host connection string
  table.insert(commands, conf.username .. "@" .. conf.host)
  return commands
end

-- Helper: Parse SFTP ls output into structured data
local function parse_ls_output(line)
  if line:match("^sftp>") or line == "" or line:match("^total") then
    return nil
  end

  local perm, links, user, group, size, month, day, time_or_year, name =
    line:match("^(%S+)%s+([%d%?]+)%s+(%S+)%s+(%S+)%s+(%d+)%s+(%a+)%s+(%d+)%s+(%S+)%s+(.+)$")
  
  if not (perm and name) then
    return nil
  end

  -- Convert month name to number
  local months = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12
  }
  local m = months[month] or 1

  -- Parse time or year
  local year, hour, min
  if time_or_year:find(":") then
    year = tonumber(os.date("%Y"))
    hour, min = time_or_year:match("^(%d+):(%d+)$")
  else
    year = tonumber(time_or_year)
    hour, min = 0, 0
  end

  -- Create timestamp
  local timestamp = os.time({
    year = year,
    month = m,
    day = tonumber(day) or 1,
    hour = tonumber(hour) or 0,
    min = tonumber(min) or 0,
    sec = 0
  })

  return {
    name = name,
    size = tonumber(size),
    mtime = timestamp,
    permissions = perm
  }
end

-- Execute SFTP command with error handling
function M.execute_command(conf, command, callback)
  local args = create_sftp_commands(conf)
  local output = {}
  local errors = {}

  -- Create temporary script file for batch commands
  local temp_script = vim.fn.tempname()
  local f = io.open(temp_script, 'w')
  if not f then
    vim.schedule(function()
      ui.show_error('Failed to create temporary script file')
    end)
    return
  end

  -- Write commands to script file
  local setup_cmds = string.format('-mkdir %s\ncd %s\n',
    vim.fn.shellescape(conf.remotePath),
    vim.fn.shellescape(conf.remotePath)
  )
  f:write(setup_cmds)
  f:write(command)
  f:write("quit\n")
  f:close()

  -- Add script to SFTP arguments
  table.insert(args, 1, "-b")
  table.insert(args, 2, temp_script)

  -- Create and configure SFTP job
  local job = Job:new({
    command = 'sftp',
    args = args,
    on_stdout = function(_, data)
      if data then
        table.insert(output, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        -- Filter out common non-error messages
        if not data:match("Couldn't create directory") and
           not data:match("remote mkdir.*: Failure") and
           not data:match("stat.*: No such file or directory") then
          table.insert(errors, data)
        end
      end
    end,
    on_exit = function(j, return_val)
      vim.schedule(function()
        -- Clean up temporary script
        os.remove(temp_script)

        if return_val == 0 or #errors == 0 then
          callback(true, output)
        else
          local error_msg = table.concat(errors, "\n")
          -- Enhance error messages with possible solutions
          if error_msg:match("Permission denied") then
            if conf.privateKeyPath then
              error_msg = error_msg .. "\nPossible issues:\n" ..
                          "1. Check SSH key permissions (should be 600)\n" ..
                          "2. Verify the key is added to the server\n" ..
                          "3. Ensure remote user has write permissions"
            else
              error_msg = error_msg .. "\nPossible issues:\n" ..
                          "1. Check username/password\n" ..
                          "2. Ensure remote user has write permissions"
            end
          end
          callback(false, { error_msg })
        end
      end)
    end
  })

  -- Handle password authentication if needed
  if conf.password then
    job:start()
    vim.schedule(function()
      job:send(conf.password .. "\n")
    end)
  else
    job:start()
  end
end

-- Recursively retrieve remote file listing
function M.get_remote_listing(conf, callback)
  local function walk_remote_dir(dir, cb)
    local batch_cmd = string.format("cd %s\nls -l\nquit\n", vim.fn.shellescape(dir))

    M.execute_command(conf, batch_cmd, function(success, output)
      if not success then
        cb(false, {})
        return
      end

      local results = {}
      for _, line in ipairs(output) do
        local file_info = parse_ls_output(line)
        if file_info then
          local full_path = dir .. "/" .. file_info.name
          results[full_path] = {
            mtime = file_info.mtime,
            size = file_info.size
          }
        end
      end

      cb(true, results)
    end)
  end

  walk_remote_dir(conf.remotePath, function(success, listing)
    if not success then
      callback(nil)
    else
      callback(listing)
    end
  end)
end

-- Test SFTP connection
function M.test_connection(conf, callback)
  local test_cmd = "pwd\nquit\n"
  M.execute_command(conf, test_cmd, function(success, output)
    if success then
      callback(true, "Connection successful")
    else
      callback(false, table.concat(output, "\n"))
    end
  end)
end

-- Get files that need to be uploaded
function M.get_files_to_upload()
  local current_dir = vim.fn.expand('%:p:h')
  local files = {}

  -- Get all files in current directory
  local local_files = vim.fn.systemlist(string.format("find '%s' -type f -maxdepth 1", current_dir))
  
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
    table.insert(files, file)
  end

  return files
end

-- Upload multiple files
function M.upload_files(conf, files)
  for _, file in ipairs(files) do
    local batch_cmd = utils.create_upload_command(file.relative_path)
    M.execute_command(conf, batch_cmd, function(success, output)
      if success then
        ui.show_success(string.format('Uploaded %s', file.relative_path))
      else
        ui.show_error(string.format('Failed to upload %s: %s', 
          file.relative_path, table.concat(output, '\n')))
      end
    end)
  end
end

return M