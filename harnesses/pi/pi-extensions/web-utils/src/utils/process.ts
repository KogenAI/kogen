import { execFile } from "node:child_process";

export interface ExecFileOptions {
	cwd?: string;
	timeoutMs?: number;
	signal?: AbortSignal;
	maxBuffer?: number;
}

export interface ExecFileResult {
	stdout: string;
	stderr: string;
	code: number;
}

export async function execFileAsync(
	command: string,
	args: string[],
	options: ExecFileOptions = {},
): Promise<ExecFileResult> {
	return new Promise((resolve) => {
		const child = execFile(
			command,
			args,
			{
				cwd: options.cwd,
				timeout: options.timeoutMs,
				maxBuffer: options.maxBuffer ?? 10 * 1024 * 1024,
			},
			(error, stdout, stderr) => {
				resolve({
					stdout: stdout ?? "",
					stderr: stderr ?? "",
					code: error ? (typeof error.code === "number" ? error.code : 1) : 0,
				});
			},
		);

		if (!options.signal) return;
		const onAbort = () => child.kill("SIGTERM");
		if (options.signal.aborted) {
			onAbort();
		} else {
			options.signal.addEventListener("abort", onAbort, { once: true });
		}
		child.once("exit", () => options.signal?.removeEventListener("abort", onAbort));
	});
}

let rgAvailableCache: boolean | null = null;

export async function isRgAvailable(): Promise<boolean> {
	if (rgAvailableCache !== null) return rgAvailableCache;
	const result = await execFileAsync("rg", ["--version"], { timeoutMs: 3000 });
	rgAvailableCache = result.code === 0;
	return rgAvailableCache;
}
