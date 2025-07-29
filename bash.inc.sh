#!/bin/bash

# Shared prompts
AI_ISSUE_PROMPT="You are working on a GitHub issue. Please read the issue details (e.g. using `gh` terminal command) and implement the necessary changes to resolve it. Issue URL:"

# Git Worktree (gwt) Functions

# Create new iTerm tab with git worktree
gwt_new() {
    local branch_name=${1:-"feature/$(date +%s)"}
    local worktree_path="$(pwd)/../$(basename $branch_name)"
    
    # Create worktree
    git worktree add "$worktree_path" -b "$branch_name"
    
    # Create temporary script
    local temp_script=$(mktemp)
    local abs_worktree_path=$(realpath "$worktree_path")
    cat > "$temp_script" << EOF
#!/bin/bash
echo "Changing to: $abs_worktree_path"
cd '$abs_worktree_path' || exit 1
printf '\033]0;$branch_name\007'
pwd
exec zsh
EOF
    chmod +x "$temp_script"
    
    # Open new terminal window
    osascript -e "
        tell application \"Terminal\"
            do script \"bash '$temp_script' && rm '$temp_script'\"
        end tell
    "
}

# Create pull request from current worktree branch to main
gwt_pr() {
    local current_branch=$(git branch --show-current)
    
    # Check if we're on main branch
    if [ "$current_branch" = "main" ]; then
        echo "Error: Cannot create PR from main branch"
        return 1
    fi
    
    # Show current status
    echo "Current git status:"
    git status
    
    # Check if there are any changes (unstaged, staged, or untracked)
    local has_changes=false
    
    # Check for unstaged changes
    if ! git diff --quiet; then
        echo "You have unstaged changes. Adding all changes..."
        git add -A
        has_changes=true
    fi
    
    # Check for untracked files
    if [ -n "$(git ls-files --others --exclude-standard)" ]; then
        echo "You have untracked files. Adding all changes..."
        git add -A
        has_changes=true
    fi
    
    # Check if there are staged changes to commit
    if ! git diff --cached --quiet; then
        echo "Committing changes..."
        git commit -m "Changes from worktree $current_branch"
        has_changes=true
    fi
    
    # Check if there are commits to push (compare with main branch)
    local commits_ahead=$(git rev-list --count main.."$current_branch" 2>/dev/null || echo "0")
    
    if [ "$commits_ahead" -eq "0" ] && [ "$has_changes" = false ]; then
        echo "Error: No commits to push. Branch '$current_branch' is up to date with main."
        return 1
    fi
    
    # Push current branch to origin
    echo "Pushing to origin..."
    git push -u origin "$current_branch"
    
    # Create pull request using GitHub CLI
    echo "Creating pull request..."
    gh pr create --base main --head "$current_branch" --title "$current_branch" --body "Auto-generated PR from worktree branch $current_branch"
}

# Remove all worktrees except main
gwt_cleanup() {
    echo "Listing all worktrees:"
    git worktree list
    
    echo ""
    echo "Removing all worktrees except main..."
    
    # Get list of worktrees with their branches (excluding main)
    local worktrees_to_remove=()
    local branches_to_delete=()
    
    # Parse worktree list to get both paths and branch names
    while IFS= read -r line; do
        if [[ $line == worktree* ]]; then
            worktree_path=$(echo "$line" | cut -d' ' -f2)
            # Skip if this is the main worktree directory
            if [ "$worktree_path" != "$(git rev-parse --show-toplevel)" ]; then
                worktrees_to_remove+=("$worktree_path")
            fi
        elif [[ $line == "branch refs/heads/"* ]] && [[ $line != "branch refs/heads/main" ]]; then
            branch_name=$(echo "$line" | sed 's/branch refs\/heads\///')
            branches_to_delete+=("$branch_name")
        fi
    done <<< "$(git worktree list --porcelain)"
    
    # Remove worktrees first
    for worktree_path in "${worktrees_to_remove[@]}"; do
        if [ -n "$worktree_path" ]; then
            echo "Removing worktree: $worktree_path"
            git worktree remove "$worktree_path" --force
        fi
    done
    
    # Then delete the associated branches
    for branch_name in "${branches_to_delete[@]}"; do
        if [ -n "$branch_name" ]; then
            echo "Deleting branch: $branch_name"
            git branch -D "$branch_name" 2>/dev/null || echo "Branch $branch_name already deleted or doesn't exist"
        fi
    done
    
    # Clean up any remaining references
    git worktree prune
    
    echo "Cleanup complete!"
    echo ""
    echo "Remaining worktrees:"
    git worktree list
}

# Notification Functions

# Simple notification function that works with hooks
notify() {
    local message="$1"
    local current_tty=$(tty 2>/dev/null)
    
    # If no TTY, try to get it from environment or process tree
    if [ -z "$current_tty" ] || [ "$current_tty" = "not a tty" ]; then
        # Try to find the TTY from the current Claude process
        current_tty=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
        if [ -z "$current_tty" ] || [ "$current_tty" = "??" ]; then
            # Try parent process
            current_tty=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
        fi
    fi
    
    # Create a temporary script that will focus the terminal when executed
    local focus_script="/tmp/claude_focus_${current_tty//\//_}.sh"
    cat > "$focus_script" << EOF
#!/bin/bash
osascript -e "
    tell application \"Terminal\"
        activate
        try
            repeat with w from 1 to count of windows
                repeat with t from 1 to count of tabs of window w
                    if tty of tab t of window w contains \"$current_tty\" then
                        set frontmost of window w to true
                        set selected tab of window w to tab t of window w
                        return
                    end if
                end repeat
            end repeat
        end try
    end tell
"
# Clean up the script after use
rm "\$0"
EOF
    chmod +x "$focus_script"
    
    # Show clickable notification using terminal-notifier
    terminal-notifier -message "$message" -title "Claude Code" -sound Glass -execute "$focus_script"
}


# AI Assistant Functions
claude_auto() {
    local github_url="$1"
    if [ -z "$github_url" ]; then
        echo "Usage: claude_auto <github-issue-url>"
        return 1
    fi
    claude --dangerously-skip-permissions "$AI_ISSUE_PROMPT $github_url"
}

gemini_auto() {
    local github_url="$1"
    if [ -z "$github_url" ]; then
        echo "Usage: gemini_auto <github-issue-url>"
        return 1
    fi
    gemini --yolo "$AI_ISSUE_PROMPT $github_url"
}

codex_auto() {
    local github_url="$1"
    if [ -z "$github_url" ]; then
        echo "Usage: codex_auto <github-issue-url>"
        return 1
    fi
    codex --full-auto "$AI_ISSUE_PROMPT $github_url"
}

# AI Assistant Aliases (for backward compatibility)
alias claude-auto='claude_auto'
alias gemini-auto='gemini_auto'
alias codex-auto='codex_auto'