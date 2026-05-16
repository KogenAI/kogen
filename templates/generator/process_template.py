#!/usr/bin/env python3
"""
Simple Jinja2-like template processor for OCG template generation.

Two output formats:
  --format=md   (default) — emit Markdown body for Claude.
  --format=toml          — emit Codex per-agent TOML (requires --config and --role).

For TOML output, the template MUST declare a `tools:` line in its YAML
frontmatter — the list determines `sandbox_mode`:
  * contains `Write` or `MultiEdit` → `workspace-write`
  * otherwise                       → `read-only`
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
    # Supported tool names: 'claude', 'codex'.
    # Dual-render pattern:
    #   {% if tool.name == 'claude' %}<claude-branch>{% else %}<codex-branch>{% endif %}
    # claude → renders claude-branch (e.g. @-imports)
    # codex → renders else-branch (e.g. → See pointers)
    if tool_name not in ('claude', 'codex'):
        raise ValueError(
            f"Unsupported tool_name: {tool_name!r} (expected 'claude' or 'codex')"
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
        # codex: keep else-branch; drop claude-branch.
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


def render_toml(template_file, config_yaml, role_name):
    """Render a per-agent Codex TOML for the given role.

    Frontmatter `tools:` is REQUIRED — the list determines sandbox_mode:
      * contains `Write` or `MultiEdit` → `workspace-write`
      * otherwise                       → `read-only`
    """
    try:
        import yaml
    except ImportError:
        sys.exit("ERROR: pyyaml not available")

    with open(config_yaml, 'r') as f:
        config = yaml.safe_load(f)
    harness = config.get('harness', {})

    with open(template_file, 'r') as f:
        raw = f.read()

    # Extract YAML frontmatter between first pair of --- inside the
    # tool.yaml_frontmatter block.
    fm_match = re.match(
        r'^\{%\s*if\s+tool\.yaml_frontmatter\s*%\}\s*---\n(.*?)\n---\s*\n\{%\s*endif\s*%\}',
        raw,
        re.DOTALL,
    )
    frontmatter = {}
    if fm_match:
        frontmatter = yaml.safe_load(fm_match.group(1)) or {}

    # Strip the {% if tool.yaml_frontmatter %}...{% endif %} block to get body.
    body = re.sub(
        r'\{%\s*if\s+tool\.yaml_frontmatter\s*%\}.*?\{%\s*endif\s*%\}\s*\n?',
        '',
        raw,
        flags=re.DOTALL,
    )
    body = re.sub(
        r'\{%\s*if\s+tool\.yaml_frontmatter\s*%\}(.*?)\{%\s*endif\s*%\}',
        '',
        body,
        flags=re.DOTALL,
    )

    # Resolve {% include 'path' %} directives recursively (handles nested includes).
    context_dir = os.environ.get('OCG_CONTEXT_DIR')
    if not context_dir:
        sys.exit(
            "ERROR: OCG_CONTEXT_DIR environment variable is not set. "
            "Run 'make install' or set it manually."
        )

    body = process_includes_recursively(body)

    # Remove any remaining Jinja-style tags.
    body = re.sub(r'\{%[^%]*%\}', '', body)
    body = body.strip()

    # ---- Derive TOML fields ----
    name_val = frontmatter.get('name', role_name)
    description_val = frontmatter.get('description', '')
    role_cfg = harness.get(role_name)
    if not role_cfg or 'codex' not in role_cfg:
        sys.exit(
            f"ERROR: process_template.py: no harness[{role_name!r}]['codex'] "
            f"entry in config.yaml; refusing to ship a silently-mistargeted role."
        )
    effort_val = role_cfg['codex']['effort']
    model_val = role_cfg['codex']['model']

    if 'tools' not in frontmatter:
        sys.exit(
            f"ERROR: process_template.py: role {role_name!r} template lacks "
            f"`tools:` frontmatter; explicit frontmatter is required for Codex generation."
        )

    tools_raw = frontmatter['tools']
    if isinstance(tools_raw, str):
        tools_list = [t.strip() for t in tools_raw.split(',') if t.strip()]
    elif isinstance(tools_raw, list):
        tools_list = [str(t).strip() for t in tools_raw if str(t).strip()]
    else:
        sys.exit(
            f"ERROR: process_template.py: role {role_name!r} `tools:` frontmatter "
            f"must be a comma-separated string or list, got {type(tools_raw).__name__}."
        )

    writable_tools = {'Write', 'MultiEdit'}
    sandbox_mode = 'workspace-write' if any(t in writable_tools for t in tools_list) else 'read-only'

    effort_map = {'high': 'high', 'medium': 'medium', 'low': 'low'}
    reasoning_effort = effort_map.get(effort_val, 'medium')

    # Use TOML literal multiline strings (''') so backslashes in body are
    # treated literally. Escape any literal ''' in body by falling back to
    # basic string with backslash escaping.
    if "'''" in body:
        body_escaped = body.replace('\\', '\\\\').replace('"', '\\"').replace('\r', '\\r')
        instr_line = f'developer_instructions = """\n{body_escaped}\n"""'
    else:
        body_for_toml = f"'''\n{body}\n'''"
        instr_line = f'developer_instructions = {body_for_toml}'

    lines = [f'name = "{name_val}"']
    if description_val:
        lines.append(f'description = "{description_val}"')
    lines.append(f'model = "{model_val}"')
    lines.append(f'model_reasoning_effort = "{reasoning_effort}"')
    lines.append(f'sandbox_mode = "{sandbox_mode}"')
    lines.append('')
    lines.append(instr_line)
    lines.append('')

    sys.stdout.write('\n'.join(lines))


if __name__ == "__main__":
    # Backward-compat: legacy callers pass three positional args
    # (template_file, tool_name, yaml_frontmatter). New TOML callers pass
    # `--format=toml --config=... --role=... <template_file>`.
    parser = argparse.ArgumentParser(description='Process OCG templates')
    parser.add_argument('--format', dest='fmt', choices=['md', 'toml'], default='md',
                        help='Output format (default: md)')
    parser.add_argument('--config', dest='config_yaml', default=None,
                        help='Path to config.yaml (required for --format=toml)')
    parser.add_argument('--role', dest='role_name', default=None,
                        help='Role name to look up in harness_models (required for --format=toml)')
    parser.add_argument('template_file', help='Template file to process')
    parser.add_argument('tool_name', nargs='?', default=None,
                        help='Tool name (claude, codex) — md format only')
    parser.add_argument('yaml_frontmatter', nargs='?', default=None,
                        help='Whether to include YAML frontmatter (true/false) — md format only')

    args = parser.parse_args()

    if args.fmt == 'toml':
        if not args.config_yaml or not args.role_name:
            sys.exit("ERROR: --format=toml requires --config and --role")
        render_toml(args.template_file, args.config_yaml, args.role_name)
    else:
        if args.tool_name is None or args.yaml_frontmatter is None:
            sys.exit("ERROR: --format=md requires positional <tool_name> <yaml_frontmatter>")
        yaml_frontmatter = args.yaml_frontmatter.lower() == 'true'
        process_template(args.template_file, args.tool_name, yaml_frontmatter, args.config_yaml)
