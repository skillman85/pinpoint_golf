import fs from "node:fs/promises";
import path from "node:path";

const inputPath = process.argv[2];
const outputPath = process.argv[3] ?? "PinpointGolf/Data/west_midlands_courses.json";

if (!inputPath) {
  throw new Error("Usage: node scripts/import-courses.mjs <input.csv> [output.json]");
}

function parseCSV(input) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;

  for (let index = 0; index < input.length; index += 1) {
    const character = input[index];

    if (inQuotes) {
      if (character === "\"") {
        if (input[index + 1] === "\"") {
          field += "\"";
          index += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += character;
      }
      continue;
    }

    if (character === "\"") {
      inQuotes = true;
    } else if (character === ",") {
      row.push(field);
      field = "";
    } else if (character === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else if (character !== "\r") {
      field += character;
    }
  }

  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }

  return rows.filter((cells) => cells.some((cell) => cell.trim() !== ""));
}

function integerValue(value) {
  const number = Number.parseInt(String(value ?? "").replace(/,/g, ""), 10);
  return Number.isFinite(number) ? number : null;
}

function doubleValue(value) {
  const number = Number.parseFloat(String(value ?? "").replace(/,/g, ""));
  return Number.isFinite(number) ? number : null;
}

function slug(value) {
  return String(value)
    .toLowerCase()
    .replace(/&/g, "and")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function teeFrom(record, markerColor) {
  const holes = [];

  for (let holeNumber = 1; holeNumber <= 18; holeNumber += 1) {
    const yards = integerValue(record[`H${holeNumber}_${markerColor}_Yards`]);
    const strokeIndex = integerValue(record[`H${holeNumber}_${markerColor}_SI`]);
    const par = integerValue(record[`H${holeNumber}_${markerColor}_Par`]);

    if (yards && par) {
      holes.push({
        number: holeNumber,
        par,
        yards,
        strokeIndex: strokeIndex ?? holeNumber,
      });
    }
  }

  const yards = integerValue(record[`Total Yards (${markerColor})`]) ?? holes.reduce((total, hole) => total + hole.yards, 0);
  if (!holes.length || !yards) {
    return null;
  }

  return {
    name: markerColor,
    markerColor,
    yards,
    par: holes.reduce((total, hole) => total + hole.par, 0) || integerValue(record["Par (overall)"]) || 0,
    slope: integerValue(record[`SR (${markerColor})`]) ?? 0,
    rating: doubleValue(record[`CR (${markerColor})`]) ?? 0,
    holes,
  };
}

const csvText = await fs.readFile(inputPath, "utf8");
const rows = parseCSV(csvText);
const headers = rows[0];
const records = rows.slice(1).map((row) => Object.fromEntries(headers.map((header, index) => [header, (row[index] ?? "").trim()])));

const courses = records.map((record) => {
  const tees = ["White", "Yellow", "Red"]
    .map((markerColor) => teeFrom(record, markerColor))
    .filter(Boolean);

  return {
    id: slug(record["Course Name"]),
    name: record["Course Name"],
    distance: "West Midlands database",
    location: [record.Location, record.Region].filter(Boolean).join(", "),
    region: record.Region,
    notes: record.Notes,
    sourceURL: record["Golfify URL"],
    tees,
    hasVerifiedScorecard: tees.some((tee) => tee.holes.length === 18),
  };
});

await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.writeFile(outputPath, `${JSON.stringify(courses, null, 2)}\n`);

const teeCount = courses.reduce((total, course) => total + course.tees.length, 0);
const fullScorecards = courses.filter((course) => course.hasVerifiedScorecard).length;
console.log(`Imported ${courses.length} courses, ${teeCount} tees, ${fullScorecards} courses with full scorecards.`);
