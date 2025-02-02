local M = {}

-- ANSI color codes
local colors = {
  reset = "\x1b[0m",
  red = "\x1b[31m",
  green = "\x1b[32m",
  yellow = "\x1b[33m",
  blue = "\x1b[34m",
  gray = "\x1b[90m"
}

-- Format file size with appropriate units
local function format_size(size)
  if size == 0 then
    return colors.gray .. "0 bytes" .. colors.reset
  end

  local units = {"bytes", "KB", "MB", "GB"}
  local unit_index = 1

  while size >= 1024 and unit_index < #units do
    size = size / 1024
    unit_index = unit_index + 1
  end

  if unit_index == 1 then
    return string.format("%s%d %s%s", colors.blue, size, units[unit_index], colors.reset)
  else
    return string.format("%s%.2f %s%s", colors.blue, size, units[unit_index], colors.reset)
  end
end

-- Format size difference with colors and symbols
function M.format_size_diff(new_size, old_size)
  local diff = new_size - old_size
  local abs_diff = math.abs(diff)
  
  if diff == 0 then
    return colors.gray .. "±0 bytes" .. colors.reset
  end

  local units = {"bytes", "KB", "MB", "GB"}
  local unit_index = 1
  local abs_display = abs_diff

  while abs_display >= 1024 and unit_index < #units do
    abs_display = abs_display / 1024
    unit_index = unit_index + 1
  end

  local sign_color = diff > 0 and colors.green or colors.red
  local sign = diff > 0 and "+" or "-"
  
  if unit_index == 1 then
    return string.format("%s%s%d %s%s", 
      sign_color, sign, abs_display, units[unit_index], colors.reset)
  else
    return string.format("%s%s%.2f %s%s", 
      sign_color, sign, abs_display, units[unit_index], colors.reset)
  end
end

-- Format timestamp in a consistent way
function M.format_timestamp(timestamp)
  if timestamp == 0 then
    return colors.gray .. "Never" .. colors.reset
  end
  return colors.yellow .. os.date("%Y-%m-%d %H:%M:%S", timestamp) .. colors.reset
end

-- Format status with colors
local function format_status(is_new, size_diff)
  if is_new then
    return colors.green .. "(New)" .. colors.reset
  else
    return string.format("(Update: %s)", size_diff)
  end
end

-- Format file list item for display
function M.format_list_item(file)
  return string.format("%-45s  %25s  %15s  %-30s",
    file.name,
    M.format_timestamp(file.info.mtime),
    format_size(file.info.size),
    format_status(file.local_mtime == 0, M.format_size_diff(file.info.size, file.local_size))
  )
end

-- Create summary header for file list
function M.create_summary_header(files_count, total_size)
  local header = string.format("\nFound %s%d files%s to download (Total size: %s)\n",
    colors.blue, files_count, colors.reset,
    format_size(total_size))
  
  -- Add column headers
  header = header .. string.format("\n%-45s  %25s  %15s  %-30s\n",
    "File Name", "Modified Date", "Size", "Status")
  
  -- Add separator line
  header = header .. string.rep("-", 120) .. "\n"
  
  return header
end

-- Format confirmation prompt
function M.format_confirmation_prompt(files_count)
  return string.format("\nProceed with downloading %s%d files%s?",
    colors.blue, files_count, colors.reset)
end

-- Show error message
function M.show_error(msg)
  vim.notify(msg, vim.log.levels.ERROR)
end

-- Show success message
function M.show_success(msg)
  vim.notify(msg, vim.log.levels.INFO)
end

-- Show warning message
function M.show_warning(msg)
  vim.notify(msg, vim.log.levels.WARN)
end

-- Create select list options
function M.create_select_opts(prompt)
  return {
    prompt = prompt,
    format_item = function(item) return item end
  }
end

return M 