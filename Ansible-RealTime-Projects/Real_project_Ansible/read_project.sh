#!/bin/bash

echo "===== INVENTORY ====="
find inventory -type f -maxdepth 3 -print

echo "===== PLAYBOOK ====="
cat playbook.yml

echo "===== ROLES AND FILES ====="
find roles -type f -print

echo "===== INVENTORY FILE CONTENTS ====="
find inventory -type f -maxdepth 3 -exec sh -c '
  for file do
    echo "----- $file -----"
    cat "$file"
  done
' sh {} +
