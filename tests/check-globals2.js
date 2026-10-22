// Global-reference checker with real lexical scope tracking.
//
// The predecessor of this script treated any name bound anywhere in the file as
// declared file-wide, which made it blind to use-before-declaration: a closure
// defined above `local function setting(...)` silently resolves `setting` to a
// global (nil at call time). That is a crash, not a warning, in Lua, so the
// scope handling has to be right.
//
// Reports every identifier read that does not resolve to a local in the lexical
// scope chain at that point.
const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');

const root = process.argv[2];

// Globals the game's Lua environment provides and the mod intentionally uses.
//
// Do not whitelist a name just to make this check pass. It flagged MasterItems
// once, and the right answer was `require("scripts/backend/master_items")` -- the
// whitelist entry would have hidden a bug that blanked the whole readout in game.
const ALLOWED = new Set([
	'_G', 'print', 'pairs', 'ipairs', 'type', 'tostring', 'tonumber', 'select',
	'pcall', 'xpcall', 'error', 'assert', 'require', 'rawget', 'rawset',
	'setmetatable', 'getmetatable', 'next', 'unpack', 'table', 'string', 'math',
	'os', 'io', 'coroutine', 'debug', 'loadstring', 'collectgarbage', 'os.exit',
	// Standard Lua. `package.loaded` is how the trait definition tables are found
	// without hard-coding a settings path that moves between builds.
	'package',
	// game / framework
	'CLASS', 'Managers', 'Mods', 'Unit', 'Actor', 'ScriptUnit', 'PhysicsWorld',
	'HEALTH_ALIVE', 'ALIVE', 'Localize', 'Color', 'Vector3', 'Vector2',
	'Matrix4x4', 'Quaternion', 'GameSession', 'NetworkLookup', 'Application',
	'UIRenderer', 'UIWidget', 'class', 'settings', 'get_mod', 'new_mod',
	'fassert', 'Fassert', 'Raycast', 'HudElementBase', 'ScriptUnit_extension',
	'Wwise', 'Profiler', 'DumpedTable', 'Awake', 'Vector3Box', 'Vector3BoxNew',
	'UIFontSettings',
]);

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

function analyze(ast) {
	const globals = new Map();
	const scopes = [new Set()];

	const declare = (name) => scopes[scopes.length - 1].add(name);

	function isDeclared(name) {
		for (let i = scopes.length - 1; i >= 0; i--) {
			if (scopes[i].has(name)) {
				return true;
			}
		}
		return false;
	}

	function pushScope() {
		scopes.push(new Set());
	}

	function popScope() {
		scopes.pop();
	}

	function bindPattern(node) {
		if (!node) {
			return;
		}
		if (node.type === 'Identifier') {
			declare(node.name);
		} else if (node.type === 'VariableDeclaration' || node.type === 'AssignmentStatement') {
			(node.variables || []).forEach(bindPattern);
		}
	}

	function walk(node, parent) {
		if (!node || typeof node !== 'object') {
			return;
		}
		if (Array.isArray(node)) {
			node.forEach((child) => walk(child, parent));
			return;
		}

		switch (node.type) {
			case 'Identifier': {
				if (parent && parent.type === 'MemberExpression' && parent.identifier === node) {
					return;
				}
				if (parent && (parent.type === 'TableKeyString' || parent.type === 'TableKey') && parent.key === node) {
					return;
				}
				if (!isDeclared(node.name) && !globals.has(node.name)) {
					globals.set(node.name, node.loc ? node.loc.start.line : '?');
				}
				return;
			}

			case 'LocalStatement': {
				// The right-hand side is evaluated before the names are bound.
				(node.init || []).forEach((child) => walk(child, node));
				(node.variables || []).forEach(bindPattern);
				return;
			}

			case 'FunctionDeclaration': {
				if (node.isLocal) {
					bindPattern(node.identifier);
				} else if (node.identifier && node.identifier.type === 'Identifier' && !globals.has(node.identifier.name)) {
					globals.set(node.identifier.name, node.identifier.loc ? node.identifier.loc.start.line : '?');
				}
				pushScope();
				(node.parameters || []).forEach(bindPattern);
				walk(node.body, node);
				popScope();
				return;
			}

			case 'ForNumericStatement': {
				walk(node.start, node);
				walk(node.end, node);
				if (node.step) {
					walk(node.step, node);
				}
				pushScope();
				bindPattern(node.variable);
				walk(node.body, node);
				popScope();
				return;
			}

			case 'ForGenericStatement': {
				(node.iterators || []).forEach((child) => walk(child, node));
				pushScope();
				(node.variables || []).forEach(bindPattern);
				walk(node.body, node);
				popScope();
				return;
			}

			case 'IfStatement': {
				(node.clauses || []).forEach((clause) => {
					if (clause.condition) {
						walk(clause.condition, clause);
					}
					pushScope();
					walk(clause.body, clause);
					popScope();
				});
				return;
			}

			case 'WhileStatement': {
				walk(node.condition, node);
				pushScope();
				walk(node.body, node);
				popScope();
				return;
			}

			case 'RepeatStatement': {
				pushScope();
				walk(node.body, node);
				walk(node.condition, node);
				popScope();
				return;
			}

			case 'DoStatement': {
				pushScope();
				walk(node.body, node);
				popScope();
				return;
			}

			default: {
				for (const key of Object.keys(node)) {
					if (key === 'type' || key === 'loc' || key === 'range' || key === 'scope') {
						continue;
					}
					walk(node[key], node);
				}
			}
		}
	}

	walk(ast, null);
	return globals;
}

let total = 0;

for (const file of files) {
	const relative = path.relative(root, file);
	const source = fs.readFileSync(file, 'utf8');
	let ast;
	try {
		ast = luaparse.parse(source, { luaVersion: '5.3', comments: false, locations: true });
	} catch (error) {
		console.log('PARSE FAIL ' + relative + ' :: ' + error.message);
		continue;
	}

	const globals = analyze(ast);
	const unexpected = [...globals.entries()].filter(([name]) => !ALLOWED.has(name));

	if (unexpected.length === 0) {
		console.log('clean   ' + relative);
	} else {
		total += unexpected.length;
		console.log('GLOBALS ' + relative);
		for (const [name, line] of unexpected) {
			console.log('          ' + name + '  (line ' + line + ')');
		}
	}
}

console.log('\n' + files.length + ' file(s), ' + total + ' unresolved global name(s)');
