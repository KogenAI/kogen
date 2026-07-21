#!/usr/bin/env node
"use strict";

const { Transform, pipeline } = require("node:stream");

class PiJsonlFilter extends Transform {
  constructor() {
    super();
    this.pending = Buffer.alloc(0);
  }

  _transform(chunk, _encoding, callback) {
    this.pending = Buffer.concat([this.pending, chunk]);
    this._emitCompleteLines(callback);
  }

  _flush(callback) {
    if (this.pending.length > 0) this._emitRecord(this.pending);
    this.pending = Buffer.alloc(0);
    callback();
  }

  _emitCompleteLines(callback) {
    let newline;
    while ((newline = this.pending.indexOf(0x0a)) !== -1) {
      const record = this.pending.subarray(0, newline + 1);
      this.pending = this.pending.subarray(newline + 1);
      this._emitRecord(record);
    }
    callback();
  }

  _emitRecord(record) {
    const hasNewline = record[record.length - 1] === 0x0a;
    let payload = hasNewline ? record.subarray(0, -1) : record;
    if (payload[payload.length - 1] === 0x0d) payload = payload.subarray(0, -1);

    try {
      const parsed = JSON.parse(payload.toString("utf8"));
      if (
        parsed !== null &&
        typeof parsed === "object" &&
        parsed.type === "message_update"
      )
        return;
    } catch (_error) {
      // Pi stderr/non-JSON bytes are part of the durable diagnostic stream.
    }

    this.push(record);
  }
}

pipeline(process.stdin, new PiJsonlFilter(), process.stdout, (error) => {
  if (!error) return;
  process.stderr.write(
    `codegen-call: Pi stream filter failed: ${error.message}\n`,
  );
  process.exitCode = 1;
});
