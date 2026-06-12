#!/bin/bash

# Shared utilities for Optimum Codegen scripts
# Source this file to get access to common variables and functions

if [ "$OCG_CLI" = "true" ]; then
    export OCG_CMD="ocg"
else
    export OCG_CMD="make"
fi
