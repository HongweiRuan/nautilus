#!/bin/bash

# Script to run all evaluation bash scripts in metabench_eval folder
# Author: Auto-generated

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${GREEN}=== MetaBench Evaluation Runner ===${NC}"
echo "Directory: $SCRIPT_DIR"
echo ""

# List of all bash evaluation scripts
EVAL_SCRIPTS=(
    "bash_navhard_eval_dd.sh"
    "bash_navhard_eval_ddv2.sh"
    "bash_navhard_eval_drivor.sh"
    "bash_navhard_eval_ltf.sh"
    "bash_navhard_eval_rap.sh"
    "bash_navhard_eval_transfuser.sh"
    "bash_navhard_eval_uniad.sh"
    "bash_navhard_eval_vad.sh"
)

# Function to run a single script
run_script() {
    local script="$1"
    echo -e "${YELLOW}Running: $script${NC}"
    if [[ -f "$script" && -x "$script" ]]; then
        bash "$script"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ $script completed successfully${NC}"
        else
            echo -e "${RED}✗ $script failed with exit code $?${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ $script not found or not executable${NC}"
        return 1
    fi
    echo ""
}

# Function to run all scripts sequentially
run_all_sequential() {
    echo -e "${GREEN}Running all scripts sequentially...${NC}"
    echo ""
    
    local failed_scripts=()
    for script in "${EVAL_SCRIPTS[@]}"; do
        if ! run_script "$script"; then
            failed_scripts+=("$script")
        fi
        # Add a small delay between scripts to avoid overwhelming kubectl
        sleep 2
    done
    
    echo -e "${GREEN}=== Summary ===${NC}"
    if [[ ${#failed_scripts[@]} -eq 0 ]]; then
        echo -e "${GREEN}All scripts completed successfully!${NC}"
    else
        echo -e "${RED}The following scripts failed:${NC}"
        for script in "${failed_scripts[@]}"; do
            echo -e "${RED}  - $script${NC}"
        done
    fi
}

# Function to show interactive menu
show_menu() {
    echo "Select an option:"
    echo "1) Run all scripts sequentially"
    echo "2) Select specific scripts to run"
    echo "3) List available scripts"
    echo "4) Exit"
    echo ""
}

# Function to select specific scripts
select_scripts() {
    echo -e "${GREEN}Available scripts:${NC}"
    for i in "${!EVAL_SCRIPTS[@]}"; do
        echo "$((i+1))) ${EVAL_SCRIPTS[i]}"
    done
    echo ""
    
    echo "Enter script numbers to run (e.g., 1 3 5) or 'all' for all scripts:"
    read -r selection
    
    if [[ "$selection" == "all" ]]; then
        run_all_sequential
        return
    fi
    
    local selected_scripts=()
    for num in $selection; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 ]] && [[ "$num" -le ${#EVAL_SCRIPTS[@]} ]]; then
            selected_scripts+=("${EVAL_SCRIPTS[$((num-1))]}")
        else
            echo -e "${RED}Invalid selection: $num${NC}"
        fi
    done
    
    if [[ ${#selected_scripts[@]} -eq 0 ]]; then
        echo -e "${RED}No valid scripts selected${NC}"
        return
    fi
    
    echo -e "${GREEN}Running selected scripts...${NC}"
    echo ""
    
    local failed_scripts=()
    for script in "${selected_scripts[@]}"; do
        if ! run_script "$script"; then
            failed_scripts+=("$script")
        fi
        sleep 2
    done
    
    echo -e "${GREEN}=== Summary ===${NC}"
    if [[ ${#failed_scripts[@]} -eq 0 ]]; then
        echo -e "${GREEN}All selected scripts completed successfully!${NC}"
    else
        echo -e "${RED}The following scripts failed:${NC}"
        for script in "${failed_scripts[@]}"; do
            echo -e "${RED}  - $script${NC}"
        done
    fi
}

# Main script logic
if [[ $# -eq 0 ]]; then
    # Interactive mode
    while true; do
        show_menu
        read -r choice
        echo ""
        
        case $choice in
            1)
                run_all_sequential
                break
                ;;
            2)
                select_scripts
                break
                ;;
            3)
                echo -e "${GREEN}Available evaluation scripts:${NC}"
                for script in "${EVAL_SCRIPTS[@]}"; do
                    if [[ -f "$script" ]]; then
                        echo -e "${GREEN}✓${NC} $script"
                    else
                        echo -e "${RED}✗${NC} $script (not found)"
                    fi
                done
                echo ""
                ;;
            4)
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                echo ""
                ;;
        esac
    done
else
    # Command line arguments
    case "$1" in
        --all|-a)
            run_all_sequential
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all, -a     Run all scripts sequentially"
            echo "  --help, -h    Show this help message"
            echo ""
            echo "If no options are provided, interactive mode will be started."
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
fi