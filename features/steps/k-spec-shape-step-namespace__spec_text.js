'use strict';
// Reads the specification text this Intent changes, relative to the repository root.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Given, Then } = require('@cucumber/cucumber');

const root = path.resolve(__dirname, '../..');

Given('k-spec-shape-step-namespace: the specification file {string}', function (rel) {
  this.specNamespacePath = rel;
  this.specNamespaceText = fs.readFileSync(path.join(root, rel), 'utf8');
});

Then('k-spec-shape-step-namespace: it contains {string}', function (text) {
  assert.ok(this.specNamespaceText.includes(text), `${this.specNamespacePath} does not contain: ${text}`);
});

Then('k-spec-shape-step-namespace: it contains:', function (text) {
  assert.ok(this.specNamespaceText.includes(text), `${this.specNamespacePath} does not contain:\n${text}`);
});

Then('k-spec-shape-step-namespace: it does not contain {string}', function (text) {
  assert.ok(!this.specNamespaceText.includes(text), `${this.specNamespacePath} still contains: ${text}`);
});
