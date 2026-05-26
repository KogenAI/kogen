#!/usr/bin/env python3
"""
Simple Jinja2-like template processor for OCG template generation.

Output format:
  --format=md   (default) — emit Markdown body for Claude or Pi.
"""

import sys
import re
import os
import argparse


def resolve_include(path):
    """Resolve an include path relative to codegen/shared/ (previously OCG_CONTEXT_DIR)."""
    # Primary: use CODEGEN_DIR/shared/ — the new canonical location after two-repo merge.
    # Fallback: OCG_CONTEXT_DIR for backwards compatibility during transition.
    codegen_dir = os.environ.get('CODEGEN_DIR')
    if codegen_dir:
        shared_dir = os.path.join(codegen_dir, 'shared')
        full_path = os.path.join(shared_dir, path)
        if os.path.exists(full_path):
            with open(full_path, 'r') as f:
                return f.read()

    # Fallback: CODEGEN_DIR auto-detected from this script's location
    # Script lives at codegen/templates/generator/process_template.py
    # so codegen root = two levels up from script dir.
    script_dir = os.path.dirname(os.path.abspath(__file__))
    auto_codegen_dir = os.path.dirname(os.path.dirname(script_dir))
    auto_shared_dir = os.path.join(auto_codegen_dir, 'shared')
    full_path = os.path.join(auto_shared_dir, path)
    if os.path.exists(full_path):
        with open(full_path, 'r') as f:
            return f.read()

    raise FileNotFoundError(
        f"Include file not found: {path}\n"
        f"Searched: {os.path.join(auto_shared_dir, path)}\n"
        f"Ensure codegen/shared/ exists (run 'make install' from codegen root)."
    )


def process_includes_recursively(content, depth=0):
    """Recursively process {% include %} directives until none remain.

    Args:
        content: Template content with include directives
        depth: Current recursion depth (prevents infinite loops)

    Returns:
        Content with all includes resolved
    """
    MAX_DEPTH = 10

    if depth >= MAX_DEPTH:
        return content

    def replace_include(match):
        include_path = match.group(1).strip().strip("'\"")
        included = resolve_include(include_path)
        if included and not included.endswith('\n'):
            included += '\n'
        return included

    # Process includes in this content
    new_content = re.sub(r'\{%\s*include\s+[\'"]([^\'"]+)[\'"]\s*%\}', replace_include, content)

    # If content changed, recursively process the result for nested includes
    if new_content != content:
        return process_includes_recursively(new_content, depth + 1)

    return new_content


def _strip_template_blocks(content, tool_name, yaml_frontmatter):
    """Strip Jinja-style {% %} blocks based on tool/frontmatter selectors."""
    # Process YAML frontmatter blocks
    if yaml_frontmatter:
        def replace_frontmatter(match):
            return match.group(1).lstrip('\n')
        content = re.sub(r'{% if tool\.yaml_frontmatter %}(.*?){% endif %}', replace_frontmatter, content, flags=re.DOTALL)
    else:
        content = re.sub(r'{% if tool\.yaml_frontmatter %}.*?{% endif %}', '', content, flags=re.DOTALL)

    # if/else/endif and simple if/endif blocks.
    # Supported tool names: 'claude', 'pi'.
    # Dual-render pattern:
    #   {% if tool.name == 'claude' %}<claude-branch>{% else %}<pi-branch>{% endif %}
    # claude → renders claude-branch (e.g. @-imports)
    # pi → renders else-branch (e.g. → See pointers)
    if tool_name not in ('claude', 'pi'):
        raise ValueError(
            f"Unsupported tool_name: {tool_name!r} (expected 'claude' or 'pi')"
        )

    if tool_name == 'claude':
        # Keep claude-branch; drop else-branch if present.
        content = re.sub(
            r'\{%\s*if\s+tool\.name\s*==\s*\'claude\'\s*%\}(.*?)\{%\s*else\s*%\}.*?\{%\s*endif\s*%\}',
            r'\1',
            content,
            flags=re.DOTALL,
        )
        # Simple if (no else).
        content = re.sub(
            r'\{%\s*if\s+tool\.name\s*==\s*\'claude\'\s*%\}(.*?)\{%\s*endif\s*%\}',
            r'\1',
            content,
            flags=re.DOTALL,
        )
    else:
        # pi: keep else-branch; drop claude-branch.
        content = re.sub(
            r'\{%\s*if\s+tool\.name\s*==\s*\'claude\'\s*%\}.*?\{%\s*else\s*%\}(.*?)\{%\s*endif\s*%\}',
            r'\1',
            content,
            flags=re.DOTALL,
        )
        # Simple if (no else) — drop entire block for non-claude.
        content = re.sub(
            r'\{%\s*if\s+tool\.name\s*==\s*\'claude\'\s*%\}.*?\{%\s*endif\s*%\}',
            '',
            content,
            flags=re.DOTALL,
        )

    # Resolve {% include 'path' %} directives recursively (handles nested includes).
    content = process_includes_recursively(content)

    # Replace simple variables.
    content = content.replace('{{ tool.name }}', tool_name)

    # Clean up any remaining template syntax.
    content = re.sub(r'{% [^}]+ %}', '', content)
    return content


def process_template(template_file, tool_name, yaml_frontmatter, config_yaml=None):
    """Process a template file with the given configuration (Markdown output).

    When tool_name == 'claude' and config_yaml is provided, the YAML frontmatter
    model: line is rewritten using harness[role][claude].model and an effort: line
    is injected immediately after it.  Role name is derived from the template
    basename (e.g. planner.md.j2 -> planner).  Silent no-op when role is absent
    from harness or config_yaml is unset.
    """
    with open(template_file, 'r') as f:
        content = f.read()
    content = _strip_template_blocks(content, tool_name, yaml_frontmatter)

    if tool_name == 'claude' and config_yaml:
        try:
            import yaml
        except ImportError:
            yaml = None

        if yaml is not None:
            with open(config_yaml, 'r') as f:
                config = yaml.safe_load(f)
            harness = config.get('harness', {})
            # Strip both extensions: planner.md.j2 -> planner.md -> planner
            role_name = os.path.splitext(os.path.splitext(os.path.basename(template_file))[0])[0]
            role_cfg = harness.get(role_name, {}).get('claude')
            if role_cfg:
                model_val = role_cfg.get('model')
                effort_val = role_cfg.get('effort')
                if model_val and effort_val:
                    # Rewrite the model: line inside the first frontmatter block
                    # (between the first pair of --- delimiters) and inject effort:.
                    def rewrite_frontmatter(m):
                        fm = m.group(1)
                        fm = re.sub(
                            r'^model:[ \t]*.+$',
                            f'model: {model_val}\neffort: {effort_val}',
                            fm,
                            flags=re.MULTILINE,
                        )
                        return f'---\n{fm}\n---'

                    content = re.sub(
                        r'^---\n(.*?)\n---',
                        rewrite_frontmatter,
                        content,
                        count=1,
                        flags=re.DOTALL,
                    )

    print(content, end='')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Process OCG templates')
    parser.add_argument('--config', dest='config_yaml', default=None,
                        help='Path to config.yaml (for model/effort frontmatter rewrite — claude only)')
    parser.add_argument('template_file', help='Template file to process')
    parser.add_argument('tool_name', nargs='?', default=None,
                        help='Tool name (claude, pi)')
    parser.add_argument('yaml_frontmatter', nargs='?', default=None,
                        help='Whether to include YAML frontmatter (true/false)')

    args = parser.parse_args()

    if args.tool_name is None or args.yaml_frontmatter is None:
        sys.exit("ERROR: requires positional <tool_name> <yaml_frontmatter>")
    yaml_frontmatter = args.yaml_frontmatter.lower() == 'true'
    process_template(args.template_file, args.tool_name, yaml_frontmatter, args.config_yaml)
