#!/usr/bin/env python3
"""
Simple Jinja2-like template processor for OCG template generation
"""

import sys
import re
import os
import argparse

def resolve_include(path):
    """Resolve an include path relative to OCG_CONTEXT_DIR."""
    context_dir = os.environ.get('OCG_CONTEXT_DIR')
    if not context_dir:
        raise RuntimeError(
            "OCG_CONTEXT_DIR environment variable is not set. "
            "Run 'make install' or set it manually."
        )
    full_path = os.path.join(context_dir, path)
    if not os.path.exists(full_path):
        raise FileNotFoundError(f"Include file not found: {full_path}")
    with open(full_path, 'r') as f:
        return f.read()

def process_template(template_file, tool_name, yaml_frontmatter):
    """Process a template file with the given configuration"""

    # Read template
    with open(template_file, 'r') as f:
        content = f.read()

    # Process YAML frontmatter blocks
    if yaml_frontmatter:
        # Keep YAML frontmatter blocks, but strip leading/trailing whitespace
        def replace_frontmatter(match):
            return match.group(1).lstrip('\n')
        content = re.sub(r'{% if tool\.yaml_frontmatter %}(.*?){% endif %}', replace_frontmatter, content, flags=re.DOTALL)
    else:
        # Remove YAML frontmatter blocks
        content = re.sub(r'{% if tool\.yaml_frontmatter %}.*?{% endif %}', '', content, flags=re.DOTALL)

    # Process tool-specific blocks - handle if/elif/endif structure
    # First handle if/elif/endif blocks
    if tool_name == 'claude':
        content = re.sub(r'{% if tool\.name == \'claude\' %}(.*?){% elif tool\.name == \'opencode\' %}.*?{% endif %}', r'\1', content, flags=re.DOTALL)
    elif tool_name == 'opencode':
        content = re.sub(r'{% if tool\.name == \'claude\' %}.*?{% elif tool\.name == \'opencode\' %}(.*?){% endif %}', r'\1', content, flags=re.DOTALL)

    # Then handle simple if/endif blocks
    if tool_name == 'claude':
        content = re.sub(r'{% if tool\.name == \'claude\' %}(.*?){% endif %}', r'\1', content, flags=re.DOTALL)
        content = re.sub(r'{% if tool\.name == \'opencode\' %}.*?{% endif %}', '', content, flags=re.DOTALL)
    elif tool_name == 'opencode':
        content = re.sub(r'{% if tool\.name == \'opencode\' %}(.*?){% endif %}', r'\1', content, flags=re.DOTALL)
        content = re.sub(r'{% if tool\.name == \'claude\' %}.*?{% endif %}', '', content, flags=re.DOTALL)

    # Process include directives — {% include 'rules/...' %}
    def replace_include(match):
        include_path = match.group(1).strip().strip("'\"")
        included = resolve_include(include_path)
        # Ensure included content ends with a newline
        if included and not included.endswith('\n'):
            included += '\n'
        return included

    content = re.sub(r'\{%\s*include\s+[\'"]([^\'"]+)[\'"]\s*%\}', replace_include, content)

    # Replace simple variables
    content = content.replace('{{ tool.name }}', tool_name)

    # Clean up any remaining template syntax
    content = re.sub(r'{% [^}]+ %}', '', content)

    # Output the processed template
    print(content, end='')

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Process OCG templates')
    parser.add_argument('template_file', help='Template file to process')
    parser.add_argument('tool_name', help='Tool name (claude or opencode)')
    parser.add_argument('yaml_frontmatter', help='Whether to include YAML frontmatter (true/false)')

    args = parser.parse_args()

    yaml_frontmatter = args.yaml_frontmatter.lower() == 'true'
    process_template(args.template_file, args.tool_name, yaml_frontmatter)