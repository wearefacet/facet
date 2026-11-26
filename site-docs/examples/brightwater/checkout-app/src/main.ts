import { AuthError, createFacetClient, oauthBrowser } from '@facetapp/sdk';
import './style.css';

// The Facet instance this app signs in to. Change it for your instance; the
// slug must match the app registration on that instance.
const FACET_URL = 'https://facet.localhost:3443';

const auth = oauthBrowser({
	slug: 'bfr-checkout',
	redirectUri: `${location.origin}/auth/callback`,
	baseUrl: FACET_URL
});
const facet = createFacetClient({ baseUrl: FACET_URL, auth });

interface BookingData {
	client_name: string;
	dates: { start: string; end: string };
	status: string;
}
interface LineData {
	item: string;
	quantity: number;
}
interface ItemData {
	name: string;
	status: string;
	serial_number: string;
}

const app = document.querySelector<HTMLDivElement>('#app')!;

function esc(value: string): string {
	return value.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function renderSignIn(): void {
	app.innerHTML = `
		<section class="card">
			<h1>Brightwater Check-out</h1>
			<p>Today's bookings, with a button to mark items out and back in.</p>
			<button id="sign-in">Sign in with Facet</button>
		</section>`;
	document.querySelector('#sign-in')!.addEventListener('click', () => {
		auth.signIn();
	});
}

function renderError(message: string): void {
	app.innerHTML = `<section class="card"><p class="error">${esc(message)}</p></section>`;
}

async function toggleItem(itemId: string, next: string): Promise<void> {
	try {
		await facet.domain('equipment').doctype<ItemData>('Item').doc(itemId).update({ status: next });
		await renderBoard();
	} catch (error) {
		renderError(describe(error));
	}
}

function describe(error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	if (message.includes('403') || message.includes('Forbidden')) {
		return `The app's grant does not reach that record. ${message}`;
	}
	return message;
}

async function renderBoard(): Promise<void> {
	// The confirmed bookings: the ones whose items are out or about to go
	// out. The period field takes no sort, so the app sorts client-side.
	const bookings =
		await facet.domain('rentals').doctype<BookingData>('Booking').list({
			filters: { status__eq: 'confirmed' },
			items: 100
		});
	const todays = bookings.data.sort((a, b) =>
		a.data.dates.start.localeCompare(b.data.dates.start)
	);

	// One items read serves every line's label and toggle button.
	const items = await facet.domain('equipment').doctype<ItemData>('Item').list({ items: 100 });
	const byId = new Map(items.data.map((row) => [row.meta.id, row]));

	const sections: string[] = [];
	for (const booking of todays) {
		const lines =
			await facet.domain('rentals').doctype('Booking').doc(booking.meta.id)
				.children<LineData>('lines').list();
		const rows = lines.data
			.map((line) => {
				const id = line.data.item.split('.').pop() ?? '';
				const item = byId.get(id);
				if (!item) return '';
				const next = item.data.status === 'out' ? 'available' : 'out';
				const label = item.data.status === 'out' ? 'Mark back in' : 'Mark out';
				const broken = item.data.status === 'in_repair';
				return `
					<tr>
						<td>${esc(item.data.name)}</td>
						<td>${esc(item.data.serial_number)}</td>
						<td>${line.data.quantity}</td>
						<td><span class="badge badge-${esc(item.data.status)}">${esc(item.data.status)}</span></td>
						<td>${
							broken
								? '<span class="hint">in repair</span>'
								: `<button data-item="${esc(id)}" data-next="${esc(next)}">${esc(label)}</button>`
						}</td>
					</tr>`;
			})
			.join('');
		sections.push(`
			<section class="card">
				<h2>${esc(booking.data.client_name)}</h2>
				<p class="hint">${esc(booking.data.dates.start)} → ${esc(booking.data.dates.end)}</p>
				<table>
					<thead><tr><th>Item</th><th>Serial</th><th>Qty</th><th>Status</th><th></th></tr></thead>
					<tbody>${rows}</tbody>
				</table>
			</section>`);
	}

	app.innerHTML = `
		<header>
			<h1>Brightwater Check-out</h1>
			<p class="hint">${todays.length} confirmed booking(s) — items go out on the start date and come back on the end date.</p>
		</header>
		${sections.join('') || '<section class="card"><p>No bookings go out today.</p></section>'}`;

	app.querySelectorAll('button[data-item]').forEach((button) => {
		const target = button as HTMLButtonElement;
		target.addEventListener('click', () =>
			toggleItem(target.dataset.item!, target.dataset.next!)
		);
	});
}

async function boot(): Promise<void> {
	// The redirect back from the consent screen lands here.
	if (location.pathname === '/auth/callback') {
		await auth.handleCallback(location.href);
		location.replace('/');
		return;
	}
	// Who is signed in? A caller with no session fails here.
	try {
		await facet.whoami();
	} catch (error) {
		if (error instanceof AuthError) {
			renderSignIn();
			return;
		}
		renderError(describe(error));
		return;
	}
	await renderBoard();
}

boot().catch((error) => renderError(describe(error)));
