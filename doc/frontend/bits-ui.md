# Bits UI — Integration Notes

Bits UI v2 (`bits-ui`) is a **headless component library** for Svelte 5 (runes). It provides accessible primitives (combobox, select, switch, dropdown menu, pagination, checkbox) with no built-in styling — all visuals come from our design tokens.

---

## Source files

All Bits UI wrappers live under `frontend/src/lib/components/`:

| File | Bits UI Parts | Purpose |
|---|---|---|
| `Toggle.svelte` | `Switch.Root` + `Switch.Thumb` | On/off switch |
| `Select.svelte` | `Select.Root`, `Select.Trigger`, `Select.Content`, `Select.Viewport`, `Select.Item`, `Select.Portal` | Value picker with floating dropdown |
| `Select.svelte` (autocomplete mode) | `Combobox.Root`, `Combobox.Input`, `Combobox.Content`, `Combobox.Viewport`, `Combobox.Item`, `Combobox.Portal` | Combobox-style select with async search and keyboard filtering — the wrapper file the Combobox sections below describe |
| `navigation/FilterMultiSelect.svelte` | `Select.Root type="multiple"`, `Select.Trigger`, `Select.Content`, `Select.Viewport`, `Select.Item`, `Select.Portal` | Compact multi-select for the filter bar's `in` operator (see [`filter-bar.md`](filter-bar.md)); same `type="multiple"` + equality-guarded sync pattern as `RbacScopeSelect` |
| `DropdownMenu.svelte` | `DropdownMenu.Root`, `DropdownMenu.Trigger`, `DropdownMenu.Content`, `DropdownMenu.Item`, `DropdownMenu.Separator`, `DropdownMenu.Portal` | Floating action menu. `triggerChild` mode makes the caller's own element the trigger (bits-ui `child`) |
| `Button.svelte` | `DropdownMenu` (via `menu` prop, through `triggerChild`) | Whole-button dropdown trigger when `caret + menu` |
| `Table.svelte` | `Checkbox.Root` (row selection), `Pagination.Root` (page nav) | Data table |

---

## Key API rules

### 1. Use `children` snippet, never `child`

Bits UI components accept a `{#snippet children(props)}` slot for custom inner content. When you use `children`, **Bits UI renders the interactive element itself** (a `<button>` for triggers, an `<input>` for combobox inputs) — your snippet only fills its children.

Do **NOT** use the `{#snippet child({ props })}` API unless you need to fully replace the rendered element. That API requires you to spread `{...props}` on the correct native element — if you miss any prop, you lose keyboard handling, ARIA attributes, click handlers, and `data-state` attributes.

```svelte
<!-- ✅ CORRECT — Bits UI renders the <button>, we fill children -->
<Select.Trigger class="select-field-wrap">
  <span class="select-field">{displayText}</span>
</Select.Trigger>

<!-- ❌ WRONG unless you spread ALL props on a <button> -->
<Select.Trigger>
  {#snippet child({ props })}
    <button {...props} class="...">...</button>
  {/snippet}
</Select.Trigger>
```

### 2. Use `children` for item content too

Menu items, select items, and pagination also use the `children` snippet. The snippet receives state data (e.g. `{ selected, highlighted }`) that you can use for conditional styling.

```svelte
<Select.Item value="abc" class="select-item">
  {#snippet children({ selected, highlighted })}
    <span class:select-item-highlighted={highlighted}>{label}</span>
  {/snippet}
</Select.Item>
```

### 3. Portal all floating content

Every dropdown/overlay must be wrapped in a `<*Portal>` component so it renders at the document root — otherwise it will be clipped by `overflow: hidden` on parent elements:

```svelte
<Select.Portal>
  <Select.Content>...</Select.Content>
</Select.Portal>

<Combobox.Portal>
  <Combobox.Content>...</Combobox.Content>
</Combobox.Portal>

<DropdownMenu.Portal>
  <DropdownMenu.Content>...</DropdownMenu.Content>
</DropdownMenu.Portal>
```

### 4. Never nest a Trigger inside a button — or a button inside a Trigger

The rule is symmetric: one interactive element per trigger, whichever direction the composition runs.

**Button inside a Trigger.** `Trigger` parts (`Select.Trigger`, `DropdownMenu.Trigger`, …) render a native `<button>`. Putting a button component (`IconButton`, `Button`) inside one emits `<button><button>…</button></button>`, which is invalid HTML: the browser repairs it during SSR, hydration then fails (`node_invalid_placement_ssr` → `hydration_mismatch`) and the page boundary crashes with an opaque error. Icon triggers fill the Trigger's children with the bare icon and carry their own button styling:

```svelte
<!-- ❌ WRONG — button in button, breaks hydration -->
<DropdownMenu.Trigger>
  <IconButton label="Options"><MoreVertical /></IconButton>
</DropdownMenu.Trigger>

<!-- ✅ CORRECT — one button, icon as children -->
<DropdownMenu.Trigger class="dm-trigger-icon" aria-label="Options">
  <MoreVertical />
</DropdownMenu.Trigger>
```

This bit `DropdownMenu`'s `trigger="icon"` mode (the Configure → Domains rows) — the fallback now styles the trigger itself via the `.dm-trigger-icon` class.

**Trigger inside a Button.** The inverse is equally invalid: `Button` with `caret + menu` used to render `DropdownMenu` inside its own `<button>` — same `<button><button>` output, same SSR repair, same hydration crash. In a production build the mismatch reached the `ErrorBoundary` and every document show page fell to "Something went wrong" (the page's only interactive invalid nesting — lists survived because they don't render this pattern). `Button`'s `menu` mode now goes through `DropdownMenu`'s `triggerChild` snippet: the whole styled button IS the trigger — the click opens the menu, `onclick` does not fire, and `menu` cannot combine with `href` (a hard error, not a silent pick).

```svelte
<!-- ❌ WRONG (Button's old internals) — Trigger rendered a second <button>
     inside the Button's own <button> -->
<button class="btn">
  Actions
  <DropdownMenu.Trigger>▼</DropdownMenu.Trigger>  <!-- <button> in <button> -->
</button>

<!-- ✅ CORRECT (Button's current internals) — the styled button IS the trigger,
     via the bits-ui `child` snippet: one element carries the trigger props -->
<DropdownMenu {items} align="end" triggerChild={menuTrigger} />
<!-- where menuTrigger spreads the bits-ui props on the Button's own <button> -->
```

When a caller needs `href` + menu (split-button semantics), render the `DropdownMenu` as a **sibling** of the link, never inside either element.

### 5. Type-single vs type-multiple

Select and Combobox require a `type` prop:

```svelte
<Select.Root type="single" bind:value>  <!-- string value -->
<Combobox.Root type="single" bind:value>  <!-- string value -->
```

Omitting `type` causes TypeScript errors because the component can't resolve whether `value` is `string` or `string[]`.

### 6. Event callback naming

Bits UI v2 uses **camelCase** event callbacks (unlike Svelte's lowercase DOM events):

| Bits UI Prop | Svelte DOM Event |
|---|---|
| `onValueChange` | — |
| `onOpenChange` | — |
| `onCheckedChange` | `onchange` |
| `onPageChange` | — |
| `onSelect` (menu items) | — |

### 7. Dropdown menu items close the menu after their handler

The `DropdownMenu.Item` `onselect` handler runs first; the menu closes after it returns. Put the item's logic directly in `onselect` — no `preventDefault` needed:

```svelte
<DropdownMenu.Item
	onselect={() => {
		doSomething(); // the menu closes after this runs
	}}
>
	Action
</DropdownMenu.Item>
```

Call `e.preventDefault()` only when the menu must stay open (rare — multi-pick or confirm-in-place surfaces):

```svelte
<DropdownMenu.Item
	onselect={(e) => {
		e.preventDefault();
		doSomething(); // the menu stays open
	}}
>
	Action
</DropdownMenu.Item>
```

---

## CSS targeting

Bits UI v2 (2.18.x) identifies its parts with **data attributes**, not CSS class names. There are no classes like `.bits-switch-root` — the DOM looks like `<button data-switch-root="" data-state="checked">`.

| Component | CSS hook |
|---|---|
| `Switch.Root` | `[data-switch-root]` + `[data-state="checked"|"unchecked"]` |
| `Select.Trigger` | `[data-state="open"|"closed"]`, `[data-disabled]` |
| `Select.Item` | `[data-highlighted]`, `[data-selected]` |
| `Combobox.Input` | Direct `<input>` element — target via class |
| `Combobox.Item` | `[data-combobox-item]`, `[data-highlighted]`, `[data-selected]` |
| `DropdownMenu.Item` | `[data-highlighted]`, `[data-disabled]` |
| `DropdownMenu.Content` | `[data-state="open"|"closed"]` |
| `Pagination.Root` | `[data-pagination-root]` |
| `Checkbox.Root` | `[data-state="checked"|"unchecked"|"indeterminate"]` |

When you need to target a Bits UI root element from a Svelte scoped stylesheet, use `:global([data-switch-root])`. **Better yet:** for checked/unchecked visual states, use the snippet props and Svelte's `class:` directive on your own wrapper elements — this avoids dependency on Bits UI's internal attribute names and scoping issues entirely.

```svelte
<!-- ✅ Safe: class: on our own element, not relying on Bits UI attributes -->
{#snippet children({ checked })}
  <span class="toggle-track" class:toggle-checked={checked}>…</span>
{/snippet}
```

```css
/* Stylesheet - works because .toggle-track is our own element */
.toggle-track.toggle-checked { background: var(--accent); }
```

### Spreading classes

Bits UI spreads `class` and other HTML attributes onto its root element via rest props. This means you can style the trigger by passing a class directly:

```svelte
<Select.Trigger class="select-field-wrap">...</Select.Trigger>
<!-- The <button> rendered by Bits UI will have class="select-field-wrap" -->
```

---

## Component details

### Toggle

```
<div.toggle-wrap>
  <Switch.Root>              ← rendered as <button data-switch-root>
    {#snippet children({ checked })}
      <span.toggle-track>
        <span.toggle-thumb>
    {/snippet}
  </Switch.Root>
  <label.toggle-label>
</div>
```

The `Switch.Root` renders a `<button>` with `role="switch"`. Click events are handled by Bits UI — the `checked` binding updates automatically. The `children` snippet receives `{ checked }` for tracking the thumb position.

### Select

```
<div.select-wrap>
  <Select.Root type="single">
    <Select.Trigger class="select-field-wrap">  ← <button>
      <span.select-field>{displayText}</span>
      <span.select-chevron>▼</span>
    </Select.Trigger>
    <Select.Portal>
      <Select.Content class="select-dropdown" align="start" sideOffset={4}>
        <Select.Viewport>
          <Select.Item value="x" class="select-item">
            {#snippet children({ selected, highlighted })}
              ...
            {/snippet}
          </Select.Item>
        </Select.Viewport>
      </Select.Content>
    </Select.Portal>
  </Select.Root>
</div>
```

**Important**: The trigger MUST be a `<button>` for proper keyboard handling. Bits UI renders it as such via `Select.Trigger`. Do not wrap it in a `<span>` or `<div>`.

The `displayText` is derived locally from the `options` array — we don't use `Select.Value` because it requires additional prop drilling. Instead:

```ts
const displayText = $derived(
  options.find((o) => o.value === value)?.label ?? (value ? value : placeholder)
);
```

### Combobox (the `Select.svelte` autocomplete wrapper)

```
<div.autocomplete-wrap>
  <Combobox.Root type="single">
    <div.autocomplete-field-wrap>
      <Combobox.Input class="autocomplete-field">  ← <input>
      <span.autocomplete-spinner>
    </div>
    <Combobox.Portal>
      <Combobox.Content class="autocomplete-list" align="start" sideOffset={4}>
        <Combobox.Viewport>
          <Combobox.Item value="x" class="autocomplete-item">
            {#snippet children({ selected, highlighted })}
              ...
            {/snippet}
          </Combobox.Item>
        </Combobox.Viewport>
      </Combobox.Content>
    </Combobox.Portal>
  </Combobox.Root>
</div>
```

The `Combobox.Input` renders an `<input>` natively. The `<Combobox.Root>` handles value binding — when a user clicks an item, the value changes. **Crucially**, the input displays the selected item's `label` only if you pass `label={item.label}` on each `Combobox.Item`; otherwise it shows the raw `value`.

For client-side filtering, pass `inputValue` as a **one-way prop** (`{inputValue}`) and maintain it in a local `$state`:

```ts
let inputValue = $state('');

// Sync input display when value changes externally
$effect(() => {
  const item = options?.find((o) => o.value === value);
  inputValue = item ? item.label : '';
});

const filteredOptions = $derived.by(() => {
  const all = options ?? [];
  if (!inputValue) return all;
  const q = inputValue.toLowerCase();
  return all.filter((o) => o.label.toLowerCase().includes(q) || o.value.toLowerCase().includes(q));
});
```

```svelte
<Combobox.Root type="single" bind:value {inputValue}>
  <Combobox.Input
    oninput={(e) => {
      inputValue = (e.target as HTMLInputElement).value;
      search?.((e.target as HTMLInputElement).value);
    }}
  />
  ...
  <Combobox.Item value="x" label="Label" />
</Combobox.Root>
```

The `oninput` handler on `Combobox.Input` updates `inputValue` locally; the one-way `{inputValue}` prop feeds it back to Bits UI so the `<input>` element's `value` stays in sync. An `$effect` syncs `inputValue` to the selected item's label when `value` changes externally (e.g. preselected value, programmatic clear).

### DropdownMenu (used by Button with `menu` prop)

```
<DropdownMenu.Root>
  <DropdownMenu.Trigger class="dm-trigger">
    {label}
    <span.dm-caret>▼</span>
  </DropdownMenu.Trigger>
  <DropdownMenu.Portal>
    <DropdownMenu.Content class="dm-content" sideOffset={4}>
      <DropdownMenu.Item onselect={(e) => { e.preventDefault(); ... }}>
      <DropdownMenu.Separator>
    </DropdownMenu.Content>
  </DropdownMenu.Portal>
</DropdownMenu.Root>
```

### Table pagination

Bits UI `Pagination.Root` replaces the manual page-number logic. It provides `{ pages, range, currentPage }` through a `children` snippet:

```svelte
<Pagination.Root perPage={pageSize} count={total} bind:page>
  {#snippet children({ pages, range, currentPage })}
    {#each pages as p}
      {#if p.type === 'ellipsis'}…{:else}{p.value}{/if}
    {/each}
  {/snippet}
</Pagination.Root>
```

Note: Bits UI uses `perPage` (not `pageSize`) and `onPageChange` (not `onpagechange`).

---

## Common pitfalls

| Pitfall | Symptom | Fix |
|---|---|---|
| Using `child` snippet without `{...props}` spread | Click doesn't work, keyboard nav broken | Switch to `children` snippet |
| No `<Portal>` wrapper | Dropdown clipped by parent `overflow:hidden` | Wrap `<Content>` in `<Portal>` |
| Missing `type="single"` on Select/Combobox | TS error on `bind:value` | Add `type="single"` |
| `onselect` menu item closes the menu before the handler finishes | — | It does not: the handler runs first, the close follows. Run the logic directly in `onselect`; call `e.preventDefault()` only to keep the menu open |
| Using Svelte lowercase event name (`onchange`) with Bits UI | Event never fires | Use Bits UI name (`onValueChange`, `onCheckedChange`, etc.) |
| `class:` directives on components | "This type of directive is not valid on components" | Use `class` prop or wrap in parent `<div>` |
| Scoped CSS on Bits UI-rendered elements (`.my-class` on `Select.Trigger`, `Combobox.Input`, etc.) | Svelte warns "Unused CSS selector" and styles don't apply — the element is rendered by the child component, so the scope hash class is never added | Use `:global(.my-class)` for any selector targeting a Bits UI-rendered element (trigger, input). Elements inside `children` snippets (your own `<span>`s) stay scoped. |
| `pageSize` prop on Pagination | "does not exist in type" | Use `perPage` prop |
| Missing `align="start"` on `Select.Content` / `Combobox.Content` | Dropdown centered on full-width trigger | Add `align="start"` |
| No `label` prop on `Combobox.Item` | Input shows raw value (e.g. `"fr"`) instead of label after selection | Pass `label={item.label}` on each `Combobox.Item` or set `inputValue = item.label` in `onValueChange` |
| `bind:inputValue` on `Combobox.Root` | Silently fails — `inputValue` prop is NOT `$bindable()` in Bits UI v2.18.x, so two-way binding doesn't propagate. Client-side filtering never updates. | Pass `inputValue` as a one-way prop (`{inputValue}`) and set it manually in `Combobox.Input`'s `oninput` handler |
| No client-side filtering logic | Dropdown always shows full option list | Derive `filteredOptions` from `inputValue` (case-insensitive match on label/value) |
| Combobox doesn't open in tests when using `fill()` | `fill()` sets the value programmatically without firing `keydown` — Bits UI opens the dropdown on `keydown`, not `oninput` | Use `userEvent.type(input, 'text')` from `vitest/browser` which simulates real keystrokes |
| `getByPlaceholderText` / `.focus()` in browser specs | Methods don't exist on the vitest-browser Locator API | Use `getByPlaceholder()` and `element().focus()` (or `click()`) instead |