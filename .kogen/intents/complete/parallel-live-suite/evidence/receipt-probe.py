"""Read-only structural probe of historical native streams; never acceptance reuse."""
import json
from pathlib import Path
root = Path('.kogen/runtime/model-delegation-proof-20260912/raw/live')
for directory in sorted(root.glob('shape-to-build-*/build-raw-streams')):
    print(f'source={directory}')
    for path in sorted(directory.glob('raw-stream-*.jsonl')):
        events = []
        for line in path.read_text().splitlines():
            try:
                obj = json.loads(line)
                if isinstance(obj, dict): events.append(obj)
            except json.JSONDecodeError:
                pass
        starts = [e.get('thread_id') for e in events if e.get('type') == 'thread.started']
        completed = [e for e in events if e.get('type') == 'turn.completed']
        messages = [e.get('item', {}).get('text', '') for e in events if e.get('type') == 'item.completed' and e.get('item', {}).get('type') == 'agent_message']
        schemas = []
        for message in messages:
            try:
                response = json.loads(message)
                if isinstance(response, dict) and 'verdict' in response:
                    schemas.append(sorted(response))
            except json.JSONDecodeError:
                pass
        print(json.dumps({'file':path.name, 'threads': starts, 'completed_count':len(completed), 'usage_maps': [isinstance(e.get('usage'),dict) for e in completed], 'reviewer_keys':schemas}))
