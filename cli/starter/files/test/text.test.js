'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { titleCase } = require('../lib/text.js');

test('titleCase upper-cases the first letter of each word', () => {
  assert.equal(titleCase('hello world'), 'Hello World');
});

test('titleCase lower-cases the rest of each word', () => {
  assert.equal(titleCase('hELLO wORLD'), 'Hello World');
});

test('titleCase splits on any whitespace and keeps it', () => {
  assert.equal(titleCase('one\ttwo  three'), 'One\tTwo  Three');
});

test('titleCase of an empty string is empty', () => {
  assert.equal(titleCase(''), '');
});
