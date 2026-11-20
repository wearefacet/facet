-- crm.CompanyMembership action functions.
-- Module pattern: return a table of exported functions.
local export = {}

-- No lifecycle hooks or named actions yet. Membership rows are created and
-- deleted directly through the parent route (POST /api/crm/Company/:id/memberships).

return export
