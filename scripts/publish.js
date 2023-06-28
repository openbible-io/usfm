const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const scope = '@openbible';
const name = `${scope}/usfm`;
const packages_dir = "npm";
const version = fs.readFileSync('build.zig.zon', 'utf8').match(/.version = "(.*)"/)[1]
console.log('publishing', version);

const zigTargets = [
	'arm-linux',
	'aarch64-linux',
	'x86_64-linux',
	'aarch64-macos',
	'x86_64-macos',
	'aarch64-windows',
	'x86_64-windows',
];

const zigToNodeOS = {
	'linux': 'linux',
	'windows': 'win32',
	'macos': 'darwin',
};

const zigToNodeCPU = {
	'arm': 'arm',
	'aarch64': 'arm64',
	'x86_64': 'x64',
};

const packageName = t => `${scope}/usfm-${t}`;

function writeNPMFiles(package_json) {
	const package_dir = path.join(packages_dir, package_json.name);
	fs.mkdirSync(package_dir, { recursive: true });

	const package_json_path = path.join(package_dir, "package.json");
	fs.writeFileSync(package_json_path, JSON.stringify(package_json, null, 2));

	const readme_path = path.join(package_dir, "README.md");
	fs.writeFileSync(readme_path, `# ${package_json.name}\nSee ${package_json.repository}`);

	const license_path = path.join(package_dir, "LICENSE.md");
	fs.copyFileSync("LICENSE.md", license_path);
}

function buildTarget(t) {
	const split = t.split('-');
	const package_json = {
		name: packageName(t),
		version,
		description: `${t} target of usfm, a usfm to json parser.`,
		repository: 'https://github.com/openbible-io/usfm',
		license: 'MIT',
		preferUnplugged: true, // Keeps yarn from compressing binary
		engines: {
			node: '>=12',
		},
		os: [zigToNodeOS[split[1]]],
		cpu: [zigToNodeCPU[split[0]]],
	};
	writeNPMFiles(package_json);
	const package_dir = path.join(packages_dir, package_json.name);

	console.log("building", package_dir);

	execSync(`zig build -Doptimize=ReleaseFast -Dtarget=${t} -p ${package_dir}`);
}

function buildRoot() {
	const package_json = {
		name,
		version,
		description: `A usfm to json parser written in zig.`,
		repository: 'https://github.com/openbible-io/usfm',
		license: 'MIT',
		engines: {
			node: '>=12',
		},
		bin: {
			"usfm": "bin/usfm",
		},
		optionalDependencies: zigTargets.reduce((acc, cur) => {
			acc[packageName(cur)] = version;
			return acc;
		}, {}),
	};
	writeNPMFiles(package_json);
	const package_dir = path.join(packages_dir, package_json.name);

	const bin_dir = path.join(package_dir, "bin");
	fs.mkdirSync(bin_dir, { recursive: true });
	const bin_path = path.join(bin_dir, "usfm");
	fs.copyFileSync(path.join(__dirname, "usfm.js"), bin_path);
}

function publishPackage(dir) {
	console.log("publishing", dir);

	try {
		execSync('npm publish --access public', { cwd: dir });
	} catch {
		// Ignore republishing. Check logs if fails.
	}
}

function publishTarget(t) {
	const package_dir = path.join(packages_dir, packageName(t));
	publishPackage(package_dir);
}

function publishRoot() {
	const package_dir = path.join(packages_dir, name);
	publishPackage(package_dir)
}

zigTargets.forEach(buildTarget);
buildRoot();

zigTargets.forEach(publishTarget);
publishRoot();
