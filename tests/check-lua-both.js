// Parses every file under BOTH Lua 5.1 and Lua 5.3.
//
// The game runs a LuaJIT/5.1-flavoured VM, but the rest of this mod's tooling uses
// fengari (5.3). Syntax that is valid in 5.3 but not in 5.1 would pass every test
// in this repo and then fail to load in the game, so the 5.1 pass is the one that
// actually matters for shipping.
const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');

const root = process.argv[2];
const files = [];

(function walk(dir) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			walk(full);
		} else if (entry.name.endsWith('.lua')) {
			files.push(full);
		}
	}
})(root);

let failed = 0;

for (const file of files) {
	const relative = path.relative(root, file);
	const source = fs.readFileSync(file, 'utf8');
	const results = [];

	for (const version of ['5.1', '5.3']) {
		try {
			luaparse.parse(source, { luaVersion: version, comments: false, scope: false });
			results.push(version + ':ok');
		} catch (error) {
			failed++;
			results.push(version + ':FAIL(' + error.message + ' @' + error.line + ':' + error.column + ')');
		}
	}

	const ok = results.every((r) => r.endsWith(':ok'));
	console.log((ok ? 'OK    ' : 'FAIL  ') + relative.padEnd(62) + results.join('  '));
}

console.log('\n' + files.length + ' file(s), ' + failed + ' parse failure(s) across both grammars');
