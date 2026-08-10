#!/bin/bash
read -p "Enter today's drop folder path: " folder
python3 ~/Downloads/procurement_analysis/load_new_data.py "$folder"