const fs = require('node:fs');

function hasWorkingRoute(markdown, expected) {
  return markdown.split(/\r?\n/).some(line => line.trim() === expected);
}

module.exports = {hasWorkingRoute};
if (require.main === module) {
  const text = fs.readFileSync(process.argv[2], 'utf8');
  const feature = fs.readFileSync(process.argv[3], 'utf8');
  const match = feature.match(/getting-started gives the working order:\s*\n\s*"""\s*\n([^\n]+)\n\s*"""/);
  if (!match) throw new Error('working order literal missing from feature');
  if (hasWorkingRoute(text, match[1].trim())) {
    console.log('working route found');
  } else {
    console.log('working route missing');
    process.exitCode = 1;
  }
}
