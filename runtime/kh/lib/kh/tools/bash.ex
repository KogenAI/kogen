defmodule Kh.Tools.Bash do
  @moduledoc "bash tool: timeout, tail truncation (2000 lines / 50KB), full output saved to a temp file when truncated."
  alias Kh.Trunc

  @mem_cap 20 * 1024 * 1024

  @parent_guard ~S"""
  use strict;
  use warnings;
  use POSIX qw(_exit);
  my ($owner, $group) = (shift @ARGV, shift @ARGV);
  my $root = $$;
  if ($group) {
    setpgrp(0,0);
    die "process-group setup failed\n" unless getpgrp(0) == $root;
  }
  my $guard = fork();
  die "parent monitor unavailable\n" unless defined($guard);
  if ($guard == 0) {
      setpgrp(0,0) or _exit(1);
      open(STDIN, '<', '/dev/null') or _exit(1);
      open(STDOUT, '>', '/dev/null') or _exit(1);
      open(STDERR, '>', '/dev/null') or _exit(1);
      while (kill(0,$owner) && kill(0, $group ? -$root : $root)) {
          select(undef,undef,undef,0.05);
      }
      if (!kill(0,$owner)) {
          if ($group) { kill(9,-$root); }
          else {
              my @pending = ($root);
              my @victims;
              while (@pending) {
                  my $p = shift @pending;
                  push @victims,$p if $p != $$;
                  open(my $kids, '-|', '/usr/bin/pgrep', '-P', $p) or next;
                  my @children = <$kids>;
                  close($kids);
                  push @pending, grep { $_ != $$ } map { chomp; 0+$_ } @children;
              }
              kill(9,reverse @victims) if @victims;
          }
      }
      _exit(0);
  }
  exec @ARGV;
  die "command exec failed\n";
  """

  def spec do
    %{
      name: "bash",
      description:
        "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last #{Trunc.max_lines()} lines or #{div(Trunc.max_bytes(), 1024)}KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "Shell command to execute"},
          "timeout" => %{"type" => "number", "description" => "Timeout in seconds (optional, no default timeout)"}
        },
        "required" => ["command"]
      }
    }
  end

  def run(%{"command" => cmd} = args, ctx) when is_binary(cmd) do
    timeout = args["timeout"]

    with :ok <- valid_timeout(timeout) do
      {code, out, status} = exec(cmd, ctx.cwd, timeout, ctx.deadline, ctx[:session_id], ctx[:bash_pgroup] == true)
      format(cmd, code, out, status, timeout, ctx)
    end
  end

  def run(_, _), do: {:error, "bash requires a string 'command'"}

  defp valid_timeout(nil), do: :ok
  defp valid_timeout(t) when is_number(t) and t > 0, do: :ok
  defp valid_timeout(_), do: {:error, "Invalid timeout: must be a finite number of seconds"}

  @doc "Run a command; -> {exit_code | nil, output_binary, :ok | :timeout | :deadline}"
  def exec(cmd, cwd, timeout_s, deadline, session_id \\ nil, bash_pgroup \\ false) do
    # The helper monitors this VM's OS lifetime, including exits OTP cannot trap.
    # Group isolation remains opt-in; the monitor uses descendants otherwise.
    {exe, args} =
      if File.exists?("/usr/bin/perl") do
        group = if bash_pgroup, do: "1", else: "0"
        {"/usr/bin/perl", ["-e", @parent_guard, System.pid(), group, "/bin/bash", "-c", "exec </dev/null\n" <> cmd]}
      else
        {"/bin/bash", ["-c", "exec </dev/null\n" <> cmd]}
      end

    port =
      Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, :hide, {:args, args}, {:cd, cwd}])

    # fast commands can exit (and close the port) before we ask; their messages are still in the mailbox
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, p} -> p
        _ -> nil
      end

    own_deadline = if timeout_s, do: Kh.Util.now_ms() + round(timeout_s * 1000), else: :infinity
    Kh.Procs.register(os_pid, session_id, bash_pgroup)
    try do
      collect(port, os_pid, [], 0, own_deadline, deadline, bash_pgroup)
    after
      Kh.Procs.unregister(os_pid, session_id)
    end
  end

  defp collect(port, os_pid, acc, size, own, global, bash_pgroup) do
    now = Kh.Util.now_ms()
    limit = if own == :infinity, do: global, else: min(own, global)

    receive do
      {^port, {:data, d}} ->
        if size < @mem_cap, do: collect(port, os_pid, [d | acc], size + byte_size(d), own, global, bash_pgroup), else: collect(port, os_pid, acc, size, own, global, bash_pgroup)

      {^port, {:exit_status, code}} ->
        {code, drain(port, acc), :ok}
    after
      max(limit - now, 0) ->
        kill_tree(os_pid, bash_pgroup)
        safe_close(port)
        status = if own != :infinity and Kh.Util.now_ms() >= own, do: :timeout, else: :deadline
        {nil, drain(port, acc), status}
    end
  end

  # After exit, pick up any output that is already buffered (background children may keep the pipe open).
  defp drain(port, acc) do
    receive do
      {^port, {:data, d}} -> drain(port, [d | acc])
    after
      50 ->
        safe_close(port)
        acc |> Enum.reverse() |> IO.iodata_to_binary() |> Kh.Util.utf8()
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  def kill_tree(pid), do: kill_tree(pid, false)
  def kill_tree(nil, _bash_pgroup), do: :ok

  def kill_tree(os_pid, bash_pgroup) do
    pids = descendants(os_pid) ++ [os_pid]
    # Group cleanup is opt-in; default retains the existing descendant-only cleanup.
    if bash_pgroup, do: System.cmd("kill", ["-9", "--", "-" <> Integer.to_string(os_pid)], stderr_to_stdout: true)
    System.cmd("kill", ["-9" | Enum.map(pids, &Integer.to_string/1)], stderr_to_stdout: true)
  catch
    _, _ -> :ok
  end

  def descendants(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        kids = out |> String.split() |> Enum.map(&String.to_integer/1)
        kids ++ Enum.flat_map(kids, &descendants/1)

      _ ->
        []
    end
  end

  defp format(_cmd, code, out, status, timeout, ctx) do
    text = truncate(out, ctx)
    text = if text == "", do: "(no output)", else: text
    cond do
      status == :timeout -> {:error, append(text, "Command timed out after #{timeout} seconds")}
      status == :deadline -> {:error, append(text, "Command aborted: overall run deadline reached")}
      code != 0 -> {:error, append(text, "Command exited with code #{code}")}
      true -> {:ok, text}
    end
  end

  defp truncate(out, ctx) do
    t = Trunc.tail(out)
    t = if t.truncated, do: Trunc.tail(String.replace_suffix(out, "\n", "")), else: t

    if t.truncated do
      dir = ctx[:tmp_dir] || System.tmp_dir!()
      File.mkdir_p(dir)
      path = Path.join(dir, "kh-bash-#{System.unique_integer([:positive])}.log")
      File.write(path, out)
      start = t.total_lines - t.output_lines + 1

      note =
        cond do
          t.last_line_partial -> "\n\n[Showing last #{Trunc.format_size(byte_size(t.content))} of line #{t.total_lines}. Full output: #{path}]"
          t.by == :lines -> "\n\n[Showing lines #{start}-#{t.total_lines} of #{t.total_lines}. Full output: #{path}]"
          true -> "\n\n[Showing lines #{start}-#{t.total_lines} of #{t.total_lines} (#{Trunc.format_size(Trunc.max_bytes())} limit). Full output: #{path}]"
        end

      t.content <> note
    else
      t.content
    end
  end

  defp append("", status), do: status
  defp append(text, status), do: text <> "\n\n" <> status
end
