def mode_problem:
  if IN("warn", "enforce") then empty else "mode \(tojson) is not warn or enforce" end;

def requirement_problems:
  if type != "object" then "is not an object"
  else
    (if (.id | type) != "string" or .id == "" then "has no id" else empty end),
    (if has("check") | not then "has no check"
     elif (.check | type) != "string" and (.check | type) != "null" then "check is not a string or null"
     else empty end),
    (if (.required | type) != "boolean" then "required is not true or false" else empty end)
  end;

if type != "object" then "is not a JSON object"
else
  (if .schema != 1 then "schema is not 1" else empty end),
  (if .stage != $stage then "stage is \(.stage | tojson), expected \($stage)" else empty end),
  (if (.page | strings | startswith("https://")) // false then empty else "page is not an https URL" end),
  (.mode | mode_problem),
  (if (.projects | type) != "object" then "projects is not an object"
   else .projects | to_entries[] | "project \(.key): \(.value.mode? // null | mode_problem)"
   end),
  (if (.requires | type) != "array" then "requires is not an array"
   else
     (.requires | to_entries[] | .key as $i | .value | requirement_problems | "requirement \($i): \(.)"),
     ([.requires[] | objects | .id | strings] | group_by(.) | map(select(length > 1) | .[0])[]
      | "requirement id \(tojson) is repeated")
   end)
end
