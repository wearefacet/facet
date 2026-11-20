// House style for D2 diagrams on the documentation site.
//
// One place owns how diagrams look. Pages write plain D2 and never repeat a
// colour: this module injects the theme overrides and the shape classes before
// every compile. See doc/site-docs.md → Diagrams.
//
// Colours come from the app's tokens (src/styles/global.css). Each theme gets
// its OWN compile, with its palette as the base override. This is deliberate:
// D2 emits a `dark-theme-overrides` block inside `@media
// (prefers-color-scheme: dark)`, and the site switches theme with a
// `data-theme` attribute, so that media block would never apply.

export const LIGHT_TOKENS = {
	surface: '#ffffff',
	surface2: '#fafbfc',
	ground: '#f4f6f8',
	sunken: '#eef1f4',
	border: '#e4e7ec',
	borderStrong: '#d2d7df',
	text: '#1a1d24',
	text2: '#5a6473',
	text3: '#646b78',
	accentInk: '#8c6410',
	ok: '#1a6b3c',
	warn: '#9a5414',
	danger: '#b8333d',
	info: '#2f5fb0',
};

export const DARK_TOKENS = {
	surface: '#11151c',
	surface2: '#151a22',
	ground: '#0b0e13',
	sunken: '#0e1218',
	border: '#222a35',
	borderStrong: '#2f3845',
	text: '#e9edf3',
	text2: '#97a1b0',
	text3: '#828d9b',
	accentInk: '#f0cc4d',
	ok: '#46b07a',
	warn: '#d97e2e',
	danger: '#e26464',
	info: '#6e93e0',
};

// D2 accepts exactly these 18 codes; any other key fails the compile
// (verified against @terrastruct/d2 0.1.33).
//
// The mapping matters:
// - A plain node is painted with B6, and B4/B5 are the container fills, so B4
//   stays the accent — a gold frame around a nested node.
// - Edges (the line AND its arrowhead) are painted with B1. B1 is also the
//   page canvas, so it must be the edge ink, not the surface: mapping it to
//   the surface draws white arrows on a white page.
const THEME_CODES = ['B1', 'B2', 'B3', 'B4', 'B5', 'B6', 'AA2', 'AA4', 'AA5', 'AB4', 'AB5', 'N1', 'N2', 'N3', 'N4', 'N5', 'N6', 'N7'];

function palette(t) {
	return {
		B1: t.text3,
		B2: t.surface2,
		B3: t.ground,
		B4: t.accentInk,
		B5: t.surface2,
		B6: t.surface2,
		AA2: t.border,
		AA4: t.surface,
		AA5: t.surface,
		AB4: t.borderStrong,
		AB5: t.border,
		N1: t.text,
		N2: t.text,
		N3: t.text2,
		N4: t.text2,
		N5: t.text2,
		N6: t.text3,
		N7: t.text,
	};
}

	function overrides(t) {
	const map = palette(t);
	const lines = THEME_CODES.map((code) => `      ${code}: "${map[code]}"`).join('\n');
	return `vars: {\n  d2-config: {\n    theme-overrides: {\n${lines}\n    }\n  }\n}`;
}

// Geometry is shared by every class: 15px text, a 2px stroke, no shadow.
// Classes differ only by shape and by the tokens they use.
const GEOMETRY = ['font-size: 15', 'stroke-width: 2', 'shadow: false'];

function classBody({ shape, radius = 6, fill, stroke, text }) {
	const keys = [`border-radius: ${radius}`, ...GEOMETRY, `fill: "${fill}"`, `stroke: "${stroke}"`, `font-color: "${text}"`];
	const head = shape ? `    shape: ${shape}\n` : '';
	return `${head}    style: { ${keys.join('; ')} }`;
}

// `node` is the default. The rest carry a job: `decision` asks a question,
// `store` is durable state, `external` is outside the boundary, `accent`
// highlights the one node that matters, and the outcome classes colour a step.
//
// Keep every node FLAT — one label, no children. A node with children is a D2
// container: D2 paints it with the accent fill (B4) and draws a large title on
// top of it, which no theme override can make look right.
const CLASSES = {
	node: { fill: 'surface2', stroke: 'borderStrong' },
	decision: { shape: 'diamond', radius: 4, fill: 'surface', stroke: 'borderStrong' },
	store: { fill: 'ground', stroke: 'borderStrong' },
	external: { fill: 'ground', stroke: 'borderStrong' },
	accent: { fill: 'surface2', stroke: 'accentInk' },
	ok: { fill: 'surface2', stroke: 'ok' },
	warn: { fill: 'surface2', stroke: 'warn' },
	danger: { fill: 'surface2', stroke: 'danger' },
	info: { fill: 'surface2', stroke: 'info' },
};

function classes(t) {
	const definitions = Object.entries(CLASSES).map(([name, spec]) => {
		const body = classBody({ ...spec, fill: t[spec.fill], stroke: t[spec.stroke], text: t.text });
		return `  ${name}: {\n${body}\n  }`;
	});
	return `classes: {\n${definitions.join('\n')}\n}`;
}

/**
 * Builds the full D2 source for one page diagram and one palette.
 *
 * Direction defaults to `down`. The content column is narrow (50rem), so a
 * vertical flow stays readable at full size while a horizontal one is scaled
 * down or scrolled. A page that sets `direction:` keeps it — use `right` for a
 * short branching flow, where the branches read better side by side.
 *
 * A node with no `class` gets `node`, so a page never renders D2's own default
 * box (sharp corners, a heavy stroke).
 *
 * The canvas stays transparent so the SVG sits on the page surface.
 */
export function styleSource(source, tokens) {
	const directed = /^\s*direction:/m.test(source) ? source : `direction: down\n${source}`;
	const defaulted = defaultNodeClass(directed);
	return `${overrides(tokens)}\n${classes(tokens)}\nstyle: {fill: transparent}\n${defaulted}`;
}

// Appends `class: node` to a shape declaration that names no class. The page
// sources use one shape per line, in the form `id: Label` or
// `id: Label {attrs}`; edges (`->`), nested property lines (`a.b: ...`) and
// comments are left alone.
function defaultNodeClass(source) {
	return source
		.split('\n')
		.map((line) => {
			if (line.includes('->') || line.includes('<-')) return line;
			const trimmed = line.trimStart();
			if (trimmed.startsWith('#') || trimmed.startsWith('...')) return line;
			const match = line.match(/^(\s*)([A-Za-z_][\w-]*)(\s*:\s*)(.+)$/);
			if (!match) return line;
			const [, indent, id, colon, rest] = match;
			const body = rest.trim();
			// A property of another shape, a map, or an explicit class.
			if (id.includes('.')) return line;
			if (body.startsWith('{') && !body.endsWith('}')) return line;
			if (body.startsWith('|') || body.startsWith('@')) return line;
			const attrs = body.match(/^(.*?)\s*\{([^}]*)\}\s*$/);
			if (attrs) {
				if (/\bclass\s*:/.test(attrs[2])) return line;
				return `${indent}${id}${colon}${attrs[1].trim()} {${attrs[2].trim()}; class: node}`;
			}
			return `${indent}${id}${colon}${body} {class: node}`;
		})
		.join('\n');
}

export const RENDER_OPTIONS = {
	layout: 'dagre',
	pad: 16,
	noXMLTag: true,
};

// A connection label carries a palette code, not a hex value, and D2's default
// (N2) paints it in the text colour. The muted ink reads better on both
// surfaces, so the renderer pins every label to N3.
export const EDGE_LABEL_COLOR = 'N3';
