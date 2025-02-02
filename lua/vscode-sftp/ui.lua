local M = {}

-- ANSI color codes
local colors = {
  reset = "\x1b[0m",
  red = "\x1b[31m",
  green = "\x1b[32m",
  yellow = "\x1b[33m",
  blue = "\x1b[34m",
  gray = "\x1b[90m",
  bold = "\x1b[1m"
}

-- Format file size with appropriate units
local function format_size(size)
  if size == 0 then
    return colors.gray .. "0 bytes" .. colors.reset
  end

  local units = {"bytes", "KB", "MB", "GB"}
  local unit_index = 1
  local display_size = size

  while display_size >= 1024 and unit_index < #units do
    display_size = display_size / 1024
    unit_index = unit_index + 1
  end

  if unit_index == 1 then
    return string.format("%s%d %s%s", 
      colors.blue, display_size, units[unit_index], colors.reset)
  else
    return string.format("%s%.2f %s%s", 
      colors.blue, display_size, units[unit_index], colors.reset)
  end
end

-- Format size difference with colors and symbols
function M.format_size_diff(new_size, old_size)
  local diff = new_size - old_size
  if diff == 0 then 
    return colors.gray .. "±0 bytes" .. colors.reset 
  end
  
  local sign = diff > 0 and "+" or "-"
  local color = diff > 0 and colors.green or colors.red
  local abs_diff = math.abs(diff)
  
  local units = {"bytes", "KB", "MB", "GB"}
  local unit_index = 1
  local display_size = abs_diff

  while display_size >= 1024 and unit_index < #units do
    display_size = display_size / 1024
    unit_index = unit_index + 1
  end

  if unit_index == 1 then
    return string.format("%s%s%d %s%s", 
      color, sign, display_size, units[unit_index], colors.reset)
  else
    return string.format("%s%s%.2f %s%s", 
      color, sign, display_size, units[unit_index], colors.reset)
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
    return colors.green .. "(New File)" .. colors.reset
  else
    return string.format("(Update: %s)", size_diff)
  end
end

-- Create summary header for file list
function M.create_summary_header(files_count, total_size)
  local total_size_str = format_size(total_size)
  -- Title with total count and size
  local header = string.format("\n %s%s%d files to process%s (Total size: %s)\n",
    colors.bold,
    colors.blue,
    files_count,
    colors.reset,
    total_size_str
  )
  
  -- Add column headers with proper spacing and alignment
  header = header .. "\n"
  header = header .. string.format(" %-50s  %-25s  %-20s  %-30s\n",
    colors.bold .. "File Name" .. colors.reset,
    colors.bold .. "Modified Date" .. colors.reset,
    colors.bold .. "Size" .. colors.reset,
    colors.bold .. "Status" .. colors.reset
  )
  
  -- Add separator line with proper width
  header = header .. " " .. string.rep("─", 128) .. "\n"
  
  return header
end

-- Format file list item for display
function M.format_list_item(file)
  local status
  if file.local_mtime == 0 then
    status = colors.green .. "(New File)" .. colors.reset
  else
    local size_diff = M.format_size_diff(file.info.size, file.local_size)
    status = string.format("(Update: %s)", size_diff)
  end

  -- Add left padding and ensure proper column spacing
  return string.format(" %-50s  %-25s  %-20s  %-30s",
    colors.blue .. file.name .. colors.reset,
    M.format_timestamp(file.info.mtime),
    format_size(file.info.size),
    status
  )
end

-- Create select options for vim.ui.select
function M.create_select_opts(prompt)
  return {
    prompt = prompt,
    format_item = function(item) return item end
  }
end

-- Format confirmation prompt
function M.format_confirmation_prompt(files_count)
  return string.format("\n %sConfirmation Required%s\n %sProcess %d files?%s",
    colors.bold,
    colors.reset,
    colors.blue,
    files_count,
    colors.reset
  )
end

-- Show error message
function M.show_error(msg)
  vim.notify(msg, vim.log.levels.ERROR)
end

-- Show success message
function M.show_success(msg)
  vim.notify(msg, vim.log.levels.INFO)
end

-- Show info message
function M.show_info(msg)
  vim.notify(msg, vim.log.levels.INFO)
end

-- Show warning message
function M.show_warning(msg)
  vim.notify(msg, vim.log.levels.WARN)
end

return M