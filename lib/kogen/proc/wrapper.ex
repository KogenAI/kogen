defmodule Kogen.Proc.Wrapper do
  @moduledoc false

  @perl "/usr/bin/perl"
  @env "/usr/bin/env"
  @grace_ms 200

  @script ~S"""
  use strict;
  use warnings;
  use Fcntl qw(F_SETFD FD_CLOEXEC);
  use IO::Select;
  use POSIX qw(:sys_wait_h _exit setsid);
  use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

  my ($log_path, $stdin_path, $timeout_ms, $grace_ms, $remove_log, $remove_stdin) =
    splice @ARGV, 0, 6;
  my @command = @ARGV;

  sub read_exact {
    my ($handle, $length) = @_;
    my $value = "";
    while (length($value) < $length) {
      my $count = sysread($handle, my $part, $length - length($value));
      return undef if !defined($count) || $count == 0;
      $value .= $part;
    }
    return $value;
  }

  sub write_error {
    my ($handle, $number) = @_;
    syswrite($handle, pack("N", $number));
  }

  sub clock_now {
    return clock_gettime(CLOCK_MONOTONIC);
  }

  sub group_alive {
    my ($group) = @_;
    return kill(0, -$group) > 0;
  }

  sub shutdown_group {
    my ($group, $grace) = @_;
    kill("TERM", -$group);
    my $deadline = clock_now() + $grace / 1000;
    while (clock_now() < $deadline && group_alive($group)) {
      select(undef, undef, undef, 0.01);
    }
    kill("KILL", -$group) if group_alive($group);
  }

  sub exit_code {
    my ($status) = @_;
    return WEXITSTATUS($status) if WIFEXITED($status);
    return 128 + WTERMSIG($status) if WIFSIGNALED($status);
    return 255;
  }

  sub remove_internal_files {
    unlink($stdin_path) if $remove_stdin;
    unlink($log_path) if $remove_log;
  }

  my $header = read_exact(*STDIN, 4);
  if (!defined $header) {
    remove_internal_files();
    exit 0;
  }
  my $payload_size = unpack("N", $header);
  my $payload = read_exact(*STDIN, $payload_size);
  if (!defined $payload) {
    remove_internal_files();
    exit 0;
  }
  my @environment = split(/\0/, $payload, -1);
  pop @environment if @environment && $environment[-1] eq "";
  my %environment;
  while (@environment) {
    my $key = shift @environment;
    $environment{$key} = shift @environment;
  }

  my $started_at = clock_now();
  my $deadline = $started_at + $timeout_ms / 1000;
  pipe(my $exec_read, my $exec_write) or do {
    print STDOUT "DONE|-|0|" . (0 + $!) . "\n";
    remove_internal_files();
    exit 0;
  };

  my $child = fork();
  if (!defined $child) {
    print STDOUT "DONE|-|0|" . (0 + $!) . "\n";
    close($exec_read);
    close($exec_write);
    remove_internal_files();
    exit 0;
  }

  if ($child == 0) {
    close($exec_read);
    my $session = setsid();
    if (!defined($session) || $session < 0) {
      write_error($exec_write, 0 + $!);
      _exit(126);
    }
    write_error($exec_write, 0);
    if (!open(STDIN, "<", $stdin_path) || !open(STDOUT, ">>", $log_path) ||
        !open(STDERR, ">&STDOUT")) {
      write_error($exec_write, 0 + $!);
      _exit(126);
    }
    %ENV = %environment;
    fcntl($exec_write, F_SETFD, FD_CLOEXEC);
    exec {$command[0]} @command;
    write_error($exec_write, 0 + $!);
    _exit(127);
  }

  close($exec_write);
  my $ready = read_exact($exec_read, 4);
  my $ready_error = defined($ready) ? unpack("N", $ready) : 5;
  my $select = IO::Select->new(*STDIN);
  my $timed_out = 0;
  my $cancelled = 0;
  my $status;
  my $child_done = 0;

  if ($ready_error != 0) {
    waitpid($child, 0);
    $status = $?;
    $child_done = 1;
  } else {
    while (!$child_done) {
      my $waited = waitpid($child, WNOHANG);
      if ($waited == $child) {
        $status = $?;
        $child_done = 1;
        last;
      }
      if (clock_now() >= $deadline) {
        $timed_out = 1;
        last;
      }
      my $wait = $deadline - clock_now();
      $wait = 0.05 if $wait > 0.05;
      my @readable = $select->can_read($wait);
      next unless @readable;
      my $count = sysread(STDIN, my $control, 256);
      if (!defined($count) || $count == 0) {
        $cancelled = 1;
        last;
      }
      if ($control =~ /TIMEOUT/) {
        $timed_out = 1;
        last;
      }
      if ($control =~ /CANCEL/) {
        $cancelled = 1;
        last;
      }
    }
  }

  if (!$child_done && $ready_error == 0) {
    shutdown_group($child, $grace_ms);
    waitpid($child, 0);
    $status = $?;
  } elsif ($child_done && $ready_error == 0) {
    shutdown_group($child, $grace_ms);
  }

  my $exec_failure = read_exact($exec_read, 4);
  my $exec_error = defined($exec_failure) ? unpack("N", $exec_failure) : $ready_error;
  my $code = $timed_out || $cancelled || $exec_error != 0 ? "-" : exit_code($status);
  print STDOUT "DONE|$code|" . ($timed_out ? 1 : 0) . "|$exec_error\n";
  remove_internal_files() if $cancelled;
  exit 0;
  """

  @spec executable() :: Path.t()
  def executable, do: @env

  @spec arguments(Path.t(), Path.t(), non_neg_integer(), boolean(), boolean(), [String.t()]) ::
          [String.t()]
  def arguments(log_path, stdin_path, timeout_ms, remove_log, remove_stdin, argv) do
    [
      "-i",
      @perl,
      "-e",
      @script,
      "--",
      log_path,
      stdin_path,
      Integer.to_string(timeout_ms),
      Integer.to_string(@grace_ms),
      flag(remove_log),
      flag(remove_stdin)
      | argv
    ]
  end

  @spec environment_frame(map()) :: binary()
  def environment_frame(env) do
    payload =
      env
      |> Enum.sort()
      |> Enum.flat_map(fn {key, value} -> [key, value] end)
      |> Enum.join(<<0>>)

    <<byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>
  end

  @spec flag(boolean()) :: String.t()
  defp flag(true), do: "1"
  defp flag(false), do: "0"
end
