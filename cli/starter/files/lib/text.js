'use strict';

function titleCase(text) {
  return text
    .split(/(\s+)/)
    .map((part) => (/^\s*$/.test(part) ? part : part.charAt(0).toUpperCase() + part.slice(1).toLowerCase()))
    .join('');
}

module.exports = { titleCase };
