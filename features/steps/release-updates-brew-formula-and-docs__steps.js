const { Given, When, Then } = require('@cucumber/cucumber');
const d = require('./release-updates-brew-formula-and-docs__driver/driver.js');
Given('release-updates-brew-formula-and-docs: a release from {string} to {string}', function(oldTag, tag) { this.brew = {oldTag, tag}; });
When('release-updates-brew-formula-and-docs: the release tap procedure runs with {string}', function(mode) { this.brew.result = d.run(process.cwd(), this.brew.oldTag, this.brew.tag, mode); });
Then('release-updates-brew-formula-and-docs: the remote formula matches SHA256SUMS', function() { d.success(this.brew.result); });
Then('release-updates-brew-formula-and-docs: the update fails visibly', function() { d.failure(this.brew.result); });
Then('release-updates-brew-formula-and-docs: publication is wired to the tap procedure', function() { d.wiring(process.cwd()); });
Then('release-updates-brew-formula-and-docs: Install documents these methods', function(table) { d.docs(process.cwd(), table.raw()); });
