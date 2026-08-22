#!/bin/bash
read -p "Enter today's drop folder path: " folder
python3 ~/Downloads/procurement_analysis/load_new_data.py "$folder"


# run ./run_load.command 
# Enter today's drop folder path: ~/Downloads/procurement_analysis/procurement_data/raw/"updated folder date"