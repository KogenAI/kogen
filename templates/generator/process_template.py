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
    # Fallback: auto-detect CODEGEN_DIR from this script's location (OCG_CONTEXT_DIR is no longer consulted).
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
    # Resolve includes FIRST so that {% if %} blocks inside fragments are
    # inlined before per-tool stripping — otherwise fragment conditionals
    # survive un-stripped and the final blanket-cleanup concatenates both branches.
    content = process_includes_recursively(content)

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

    # Replace simple variables.
    content = content.replace('{{ tool.name }}', tool_name)

    # Clean up any remaining template syntax.
    content = re.sub(r'{% [^}]+ %}', '', content)
    return content


def _map_pi_tools(tools_csv, tool_map, template_file):
    """Translate a claude tools: CSV to pi tool names, de-duped, order-preserved.

    Aborts loud (SystemExit) on any claude tool with no tool_map entry —
    a silently-narrowed allowlist is an invisible capability removal. Pi
    itself silently ignores unknown --tools names at runtime, so generation
    time is the only guard against this.
    """
    mapped = []
    for raw in tools_csv.split(','):
        name = raw.strip()
        if not name:
            continue
        if name not in tool_map:
            raise SystemExit(
                f"process_template.py: no pi tool_map entry for claude tool {name!r}"
                f" (template {template_file}); add it to config.yaml tools.pi.tool_map"
                f" or remove the tool from the template frontmatter"
            )
        pi_name = tool_map[name]
        if pi_name not in mapped:
            mapped.append(pi_name)
    return ', '.join(mapped)


def process_template(template_file, tool_name, yaml_frontmatter, config_yaml=None):
    """Process a template file with the given configuration (Markdown output).

    When tool_name == 'claude' and config_yaml is provided, the YAML frontmatter
    model: line is rewritten using harness[role][claude].model and an effort: line
    is injected immediately after it.  Role name is derived from the template
    basename (e.g. reviewer-static.md.j2 -> reviewer-static).

    Only templates carrying a `model:` frontmatter line are treated as agent-role
    templates and are REQUIRED to resolve a role_cfg (fail loud if absent/incomplete).
    Templates with no `model:` line (e.g. slash commands) are not roles and are
    passed through unchanged — this is the only legitimate no-op path.
    """
    with open(template_file, 'r') as f:
        content = f.read()
    content = _strip_template_blocks(content, tool_name, yaml_frontmatter)

    if tool_name == 'claude' and config_yaml:
        try:
            import yaml
        except ImportError:
            raise SystemExit(
                "process_template.py: PyYAML required for claude config rendering but not installed"
                " — pip3 install pyyaml"
            )

        with open(config_yaml, 'r') as f:
            config = yaml.safe_load(f)
        harness = config.get('harness', {})
        # Strip both extensions: reviewer-static.md.j2 -> reviewer-static.md -> reviewer-static
        role_name = os.path.splitext(os.path.splitext(os.path.basename(template_file))[0])[0]

        # Only agent-role templates carry a model: line in their frontmatter.
        # Slash-command templates (e.g. poke-holes.md.j2) have no model: line
        # and are not roles — skip the role_cfg requirement entirely for them.
        has_model_line = re.search(r'^---\n.*?^model:[ \t]*.+$.*?^---', content, flags=re.MULTILINE | re.DOTALL)

        if has_model_line:
            role_cfg = harness.get(role_name, {}).get('claude')
            if not role_cfg:
                raise SystemExit(
                    f"process_template.py: role '{role_name}' missing from config.yaml harness map"
                    f" (template {template_file} has a model: line and must resolve a claude role_cfg)"
                )
            model_val = role_cfg.get('model')
            effort_val = role_cfg.get('effort')
            if not model_val or not effort_val:
                raise SystemExit(
                    f"process_template.py: role '{role_name}' claude config missing model/effort"
                    f" (harness.{role_name}.claude = {role_cfg!r})"
                )

            # Rewrite the model: line inside the first frontmatter block
            # (between the first pair of --- delimiters) and inject effort:.
            def rewrite_frontmatter(m):
                fm = m.group(1)
                fm, n = re.subn(
                    r'^model:[ \t]*.+$',
                    f'model: {model_val}\neffort: {effort_val}',
                    fm,
                    count=1,
                    flags=re.MULTILINE,
                )
                if n != 1:
                    raise SystemExit(
                        f"process_template.py: expected exactly one model: line in frontmatter"
                        f" of {template_file}, found {n}"
                    )
                return f'---\n{fm}\n---'

            content = re.sub(
                r'^---\n(.*?)\n---',
                rewrite_frontmatter,
                content,
                count=1,
                flags=re.DOTALL,
            )

    if tool_name == 'pi' and config_yaml:
        try:
            import yaml
        except ImportError:
            raise SystemExit(
                "process_template.py: PyYAML required for pi config rendering but not installed"
                " — pip3 install pyyaml"
            )

        with open(config_yaml, 'r') as f:
            config = yaml.safe_load(f)
        tool_map = config.get('tools', {}).get('pi', {}).get('tool_map', {})

        # Only rewrite when a frontmatter block with a tools: line is present.
        # Slash-command templates carry description:-only frontmatter (no
        # tools: line) and must render unchanged — this is the only
        # legitimate no-op path.
        def rewrite_pi_frontmatter(m):
            fm = m.group(1)

            def rewrite_tools_line(tm):
                mapped = _map_pi_tools(tm.group(1), tool_map, template_file)
                return f'tools: {mapped}'

            fm, n = re.subn(
                r'^tools:[ \t]*(.+)$',
                rewrite_tools_line,
                fm,
                count=1,
                flags=re.MULTILINE,
            )
            if n == 0:
                return f'---\n{m.group(1)}\n---'
            return f'---\n{fm}\n---'

        content = re.sub(
            r'^---\n(.*?)\n---',
            rewrite_pi_frontmatter,
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
