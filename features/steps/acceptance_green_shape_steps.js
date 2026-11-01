'use strict';
// Bind the reused suite to the running acceptance runner, not its npm-local copy.
const { createRequire } = require('node:module');
const suiteRequire = createRequire(require.resolve('../../test/acceptance/support/world'));
const active = require('@cucumber/cucumber');
const suiteCucumber = suiteRequire.resolve('@cucumber/cucumber');
require.cache[suiteCucumber] = { id: suiteCucumber, filename: suiteCucumber, loaded: true, exports: active };
require('../../test/acceptance/support/world');
require('../../test/acceptance/support/hooks');
require('../../test/acceptance/steps/steps');
