const fs = require('node:fs');
const path = require('node:path');
const { defineStep } = require('@cucumber/cucumber');
const { dispatch } = require('../support/handlers');

const repository = path.resolve(__dirname, '../../..');
const vocabulary = fs.readFileSync(path.join(repository, 'spec/features/STEPS.md'), 'utf8');
const block = vocabulary.match(/```steps\s*\n([\s\S]*?)\n```/);
if (!block) throw new Error('spec/features/STEPS.md has no steps block');

function captureCount(source) {
  let count = 0;
  let escaped = false;
  let inClass = false;
  for (let i = 0; i < source.length; i++) {
    const char = source[i];
    if (escaped) { escaped = false; continue; }
    if (char === '\\') { escaped = true; continue; }
    if (char === '[') { inClass = true; continue; }
    if (char === ']') { inClass = false; continue; }
    if (!inClass && char === '(' && source[i + 1] !== '?') count++;
  }
  return count;
}

const patterns = block[1].split(/\r?\n/).filter(Boolean);
for (const source of patterns) {
  const pattern = new RegExp(source);
  const captures = captureCount(source);
  const parameters = Array.from({ length: captures + 1 }, (_, index) => `arg${index}`).join(', ');
  const definition = new Function('dispatch', 'source', 'captures', `
    return function (${parameters}) {
      const values = Array.from(arguments);
      const args = values.slice(0, captures);
      const callback = typeof values[captures] === 'function' ? values[captures] : null;
      const attachment = callback ? undefined : (values.length > captures ? values[captures] : undefined);
      const pending = dispatch(this, source, args, attachment);
      if (callback) {
        pending.then(() => callback(), callback);
        return;
      }
      return pending;
    };
  `)(dispatch, source, captures);
  defineStep(pattern, definition);
}
