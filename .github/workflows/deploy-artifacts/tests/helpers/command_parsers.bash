#!/usr/bin/env bash
# Command parsing functions for bats tests

# Parse a jf rt upload command into structured data
# Usage: parse_jf_upload_command "jf rt upload ..."
# Returns: associative array with keys: file_path, repo, build_name, build_number, project, target_props, deb_path, flat
parse_jf_upload_command() {
  local cmd="$1"
  local -A result=()
  
  # Extract file path (first argument after "jf rt upload")
  if [[ $cmd =~ jf\ +rt\ +upload\ +([^\ ]+) ]]; then
    result[file_path]="${BASH_REMATCH[1]}"
  fi
  
  # Extract repository name (second argument after file path)
  if [[ $cmd =~ jf\ +rt\ +upload\ +[^\ ]+\ +([^\ ]+) ]]; then
    result[repo]="${BASH_REMATCH[1]}"
  fi
  
  # Extract --build-name value
  if [[ $cmd =~ --build-name=([^\ ]+) ]]; then
    result[build_name]="${BASH_REMATCH[1]}"
  fi
  
  # Extract --build-number value
  if [[ $cmd =~ --build-number=([^\ ]+) ]]; then
    result[build_number]="${BASH_REMATCH[1]}"
  fi
  
  # Extract --project value
  if [[ $cmd =~ --project=([^\ ]+) ]]; then
    result[project]="${BASH_REMATCH[1]}"
  fi
  
  # Extract --target-props value (may contain spaces, so use quotes)
  # Try quoted version first - match everything between quotes
  local quote='"'
  if [[ $cmd =~ --target-props\ +${quote}([^${quote}]+)${quote} ]]; then
    result[target_props]="${BASH_REMATCH[1]}"
  elif [[ $cmd =~ --target-props\ +([^\ ]+) ]]; then
    result[target_props]="${BASH_REMATCH[1]}"
  fi
  
  # Extract --deb path (if present)
  if [[ $cmd =~ --deb\ +([^\ ]+) ]]; then
    result[deb_path]="${BASH_REMATCH[1]}"
  fi
  
  # Check for --flat=false
  if [[ $cmd =~ --flat=false ]]; then
    result[flat]="false"
  else
    result[flat]="true"
  fi
  
  # Return results via global associative array
  # Note: bash doesn't support returning associative arrays directly
  # So we'll use a different approach - return via stdout as key=value pairs
  for key in "${!result[@]}"; do
    echo "${key}=${result[$key]}"
  done
}

# Parse target-props string into associative array
# Usage: parse_target_props "key1=value1;key2=value2"
# Returns: key=value pairs via stdout
parse_target_props() {
  local props="$1"
  local IFS=';'
  for prop in $props; do
    if [[ $prop =~ ^([^=]+)=(.*)$ ]]; then
      echo "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    fi
  done
}

# Parse a jf rt build-publish or build-append command
# Usage: parse_jf_build_command "jf rt build-publish ..."
# Returns: key=value pairs via stdout
parse_jf_build_command() {
  local cmd="$1"
  local -A result=()
  
  # Determine command type
  if [[ $cmd =~ jf\ +rt\ +build-publish ]]; then
    result[command_type]="build-publish"
    # Extract build-name and build-number
    if [[ $cmd =~ jf\ +rt\ +build-publish\ +([^\ ]+)\ +([^\ ]+) ]]; then
      result[build_name]="${BASH_REMATCH[1]}"
      result[build_number]="${BASH_REMATCH[2]}"
    fi
  elif [[ $cmd =~ jf\ +rt\ +build-append ]]; then
    result[command_type]="build-append"
    # Extract parent build-name, parent build-number, child build-name, child build-number
    if [[ $cmd =~ jf\ +rt\ +build-append\ +([^\ ]+)\ +([^\ ]+)\ +([^\ ]+)\ +([^\ ]+) ]]; then
      result[parent_build_name]="${BASH_REMATCH[1]}"
      result[parent_build_number]="${BASH_REMATCH[2]}"
      result[child_build_name]="${BASH_REMATCH[3]}"
      result[child_build_number]="${BASH_REMATCH[4]}"
    fi
  fi
  
  # Extract --project value
  if [[ $cmd =~ --project=([^\ ]+) ]]; then
    result[project]="${BASH_REMATCH[1]}"
  fi
  
  # Return results
  for key in "${!result[@]}"; do
    echo "${key}=${result[$key]}"
  done
}

# Parse a jf nuget push command into structured data
# Usage: parse_jf_nuget_push_command "jf nuget push ..."
# Returns: key=value pairs via stdout
parse_jf_nuget_push_command() {
  local cmd="$1"
  local -A result=()
  
  # Extract file path (first argument after "jf nuget push")
  if [[ $cmd =~ jf\ +nuget\ +push\ +([^\ ]+) ]]; then
    result[file_path]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ -Source\ +([^\ ]+) ]]; then
    result[source]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ --build-name=([^\ ]+) ]]; then
    result[build_name]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ --build-number=([^\ ]+) ]]; then
    result[build_number]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ --project=([^\ ]+) ]]; then
    result[project]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ --skip-duplicate ]]; then
    result[skip_duplicate]="true"
  fi
  
  # Return results
  for key in "${!result[@]}"; do
    echo "${key}=${result[$key]}"
  done
}

# Parse a nuget sources Add command
# Usage: parse_nuget_sources_command "nuget sources Add ..."
# Returns: key=value pairs via stdout
parse_nuget_sources_command() {
  local cmd="$1"
  local -A result=()
  
  # Extract source name (-Name value)
  if [[ $cmd =~ -Name\ +([^\ ]+) ]]; then
    result[name]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ -Source\ +([^\ ]+) ]]; then
    result[source]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ -username\ +([^\ ]+) ]]; then
    result[username]="${BASH_REMATCH[1]}"
  fi
  
  # Extract password (-password value, may be masked)
  if [[ $cmd =~ -password\ +([^\ ]+) ]]; then
    result[password]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ -NonInteractive ]]; then
    result[non_interactive]="true"
  fi
  
  for key in "${!result[@]}"; do
    echo "${key}=${result[$key]}"
  done
}

# Parse a nuget setapikey command
# Usage: parse_nuget_setapikey_command "nuget setapikey ..."
# Returns: key=value pairs via stdout
parse_nuget_setapikey_command() {
  local cmd="$1"
  local -A result=()
  
  # Extract API key (first argument after "nuget setapikey")
  if [[ $cmd =~ nuget\ +setapikey\ +([^\ ]+) ]]; then
    result[api_key]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ -Source\ +([^\ ]+) ]]; then
    result[source]="${BASH_REMATCH[1]}"
  fi
  
  if [[ $cmd =~ -NonInteractive ]]; then
    result[non_interactive]="true"
  fi
  
  for key in "${!result[@]}"; do
    echo "${key}=${result[$key]}"
  done
}

# Extract all jf rt upload commands from output
# Usage: extract_upload_commands "$output"
# Returns: array of commands (one per line)
extract_upload_commands() {
  local output="$1"
  # Strip ANSI color codes and extract commands with leading spaces
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^\s+(jf rt upload|jf nuget push)" | sed 's/^\s*//'
}

# Extract all nuget commands from output
# Usage: extract_nuget_commands "$output"
# Returns: array of commands (one per line)
extract_nuget_commands() {
  local output="$1"
  # Strip ANSI color codes and extract NuGet commands with leading spaces
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^\s+(nuget\s+(sources|setapikey)|jf\s+nuget\s+push)" | sed 's/^\s*//'
}

# Extract all jf rt build-* commands from output
# Usage: extract_build_commands "$output"
# Returns: array of commands (one per line)
extract_build_commands() {
  local output="$1"
  # Strip ANSI color codes and extract commands with leading spaces
  echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^\s+jf rt build-" | sed 's/^\s*//'
}
