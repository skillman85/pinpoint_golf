import { hasFirebaseWebAppId } from "./firebase.js";

const state = {
  tab: "home",
  signedIn: false,
  user: {
    name: "Guest Golfer",
    handicap: 8.0,
    homeClub: "Home Club"
  },
  rounds: [],
  liveRound: null,
  friends: [
    { id: "andy", name: "Andy Harley", handicap: 9.4, latest: "81 at Wergs Golf Club" }
  ],
  groups: [
    { id: "society", name: "Saturday Society", players: 20 }
  ],
  liveGame: {
    name: "Society Stableford",
    course: "Wergs Golf Club",
    players: [
      { name: "James", points: 0, holes: 0 },
      { name: "Andy", points: 0, holes: 0 },
      { name: "Guest", points: 0, holes: 0 }
    ]
  }
};

const demoCourse = {
  name: "Wergs Golf Club",
  tee: "Yellow",
  courseHandicap: 5,
  holes: [
    { number: 1, par: 4, yards: 277, si: 17 },
    { number: 2, par: 5, yards: 499, si: 7 },
    { number: 3, par: 4, yards: 315, si: 13 },
    { number: 4, par: 4, yards: 318, si: 3 },
    { number: 5, par: 3, yards: 175, si: 11 },
    { number: 6, par: 4, yards: 383, si: 1 },
    { number: 7, par: 5, yards: 502, si: 9 },
    { number: 8, par: 5, yards: 431, si: 15 },
    { number: 9, par: 3, yards: 173, si: 5 }
  ]
};

const app = document.querySelector("#app");

function render() {
  app.innerHTML = `
    <main class="app-shell">
      ${state.signedIn ? "" : renderAuthPanel()}
      ${renderTab()}
      ${renderNav()}
    </main>
  `;
  bindEvents();
}

function renderAuthPanel() {
  return `
    <section class="auth-card">
      <div>
        <p class="eyebrow">Precision Golf account</p>
        <h1>Play anywhere</h1>
        <p>Sign in support is ready for Firebase Auth. Web app ID ${hasFirebaseWebAppId ? "configured" : "still needed"}.</p>
      </div>
      <button class="primary small" data-action="sign-in">Continue</button>
    </section>
  `;
}

function renderTab() {
  switch (state.tab) {
    case "round":
      return renderRound();
    case "friends":
      return renderFriends();
    case "groups":
      return renderGroups();
    case "settings":
      return renderSettings();
    default:
      return renderHome();
  }
}

function renderHome() {
  const stats = seasonStats();
  return `
    <section class="profile-card">
      <div class="avatar">${initials(state.user.name)}</div>
      <div>
        <h1>${state.user.name}</h1>
        <p>${state.user.homeClub}</p>
        <div class="chip-row">
          <span>${state.rounds.length} rounds logged</span>
          <span>HI ${state.user.handicap.toFixed(1)}</span>
        </div>
      </div>
    </section>

    <section class="hero-card">
      <div>
        <p class="eyebrow">2026 Season</p>
        <h2>Scoring Average</h2>
        <p>${state.rounds.length || 0} rounds</p>
      </div>
      <button class="new-round" data-tab="round">+ New Round</button>
      <strong>${stats.gross}</strong>
      <span>gross per round</span>
    </section>

    <section class="metric-grid">
      ${metric("Stableford", stats.stableford)}
      ${metric("Putts", stats.putts)}
      ${metric("Fairways", stats.fairways)}
      ${metric("GIR", stats.gir)}
      ${metric("Scramble", stats.scramble)}
      ${metric("Penalties", stats.penalties)}
    </section>

    <section class="card">
      <div class="section-title">
        <h2>Live Group</h2>
        <span>${state.liveGame.course}</span>
      </div>
      ${renderLeaderboard()}
    </section>
  `;
}

function renderRound() {
  if (!state.liveRound) {
    return `
      <section class="header-card">
        <p class="eyebrow">New Round</p>
        <h1>Choose round type</h1>
        <p>Individual scoring first, with matchplay and group Stableford using the same score entry flow.</p>
      </section>
      <section class="round-type-grid">
        ${roundType("Individual", "Score your own card", "figure.golf")}
        ${roundType("Matchplay", "Side match against a friend", "flag.2")}
        ${roundType("Group Stableford", "Live society leaderboard", "person.3")}
      </section>
      <section class="card">
        <div class="section-title">
          <h2>${demoCourse.name}</h2>
          <span>${demoCourse.tee} tees</span>
        </div>
        <button class="primary" data-action="start-round">Start Individual Round</button>
      </section>
    `;
  }

  const hole = demoCourse.holes[state.liveRound.index];
  const entry = state.liveRound.entries[state.liveRound.index];
  const totalGross = state.liveRound.entries.reduce((sum, item) => sum + item.score, 0);
  const totalPoints = state.liveRound.entries.reduce((sum, item, index) => sum + stableford(item.score, demoCourse.holes[index]), 0);

  return `
    <section class="live-header">
      <p>${demoCourse.name}</p>
      <h1>Hole ${hole.number}</h1>
      <div class="hole-pills">
        <span>Par ${hole.par}</span>
        <span>${hole.yards} yds</span>
        <span>SI ${hole.si}</span>
      </div>
      <div class="score-tiles">
        ${scoreTile("Gross", totalGross || 0)}
        ${scoreTile("Points", totalPoints)}
        ${scoreTile("CH", demoCourse.courseHandicap)}
      </div>
    </section>

    <section class="card">
      <div class="hole-nav">
        <button data-action="prev-hole">‹</button>
        <strong>Hole ${hole.number} of ${demoCourse.holes.length}</strong>
        <button data-action="next-hole">›</button>
      </div>
      <div class="scorepad">
        ${[1, 2, 3, 4, 5, 6, 7, 8, 9].map((score) => scoreButton(score, hole, entry)).join("")}
      </div>
      <div class="stat-row">
        <label>Putts</label>
        <div>
          <button data-action="putts-minus">−</button>
          <strong>${entry.puttsTouched ? entry.putts : "--"}</strong>
          <button data-action="putts-plus">+</button>
        </div>
      </div>
      <button class="primary" data-action="save-hole">${state.liveRound.index === demoCourse.holes.length - 1 ? "Finish Round" : "Next Hole"}</button>
    </section>
  `;
}

function renderFriends() {
  return `
    <section class="header-card">
      <p class="eyebrow">Friends</p>
      <h1>Friend activity</h1>
      <p>Latest 3 friend rounds will sit here, with profile and scorecard drill-in.</p>
    </section>
    ${state.friends.map((friend) => `
      <section class="friend-card">
        <div class="avatar small-avatar">${initials(friend.name)}</div>
        <div>
          <h2>${friend.name}</h2>
          <p>${friend.latest}</p>
        </div>
        <button class="secondary">Profile</button>
      </section>
    `).join("")}
  `;
}

function renderGroups() {
  return `
    <section class="header-card">
      <p class="eyebrow">Groups</p>
      <h1>Live competitions</h1>
      <p>Create a group Stableford game for society days and let every player enter their own card.</p>
    </section>
    <section class="card">
      <div class="section-title">
        <h2>${state.liveGame.name}</h2>
        <span>${state.liveGame.players.length} players</span>
      </div>
      ${renderLeaderboard()}
      <button class="primary" data-tab="round">Enter Score</button>
    </section>
  `;
}

function renderSettings() {
  return `
    <section class="header-card">
      <p class="eyebrow">Settings</p>
      <h1>Account & sync</h1>
      <p>Firebase Auth, profile sync, backups and course cache will live here just like iOS.</p>
    </section>
    <section class="card">
      <label class="input-label">Name</label>
      <input value="${state.user.name}" data-field="name" />
      <label class="input-label">Handicap index</label>
      <input type="number" step="0.1" value="${state.user.handicap}" data-field="handicap" />
      <button class="primary" data-action="save-profile">Save Profile</button>
    </section>
  `;
}

function renderNav() {
  const tabs = [
    ["home", "Home"],
    ["round", "Round"],
    ["friends", "Friends"],
    ["groups", "Groups"],
    ["settings", "Settings"]
  ];
  return `<nav>${tabs.map(([id, label]) => `<button class="${state.tab === id ? "active" : ""}" data-tab="${id}">${label}</button>`).join("")}</nav>`;
}

function bindEvents() {
  document.querySelectorAll("[data-tab]").forEach((button) => {
    button.addEventListener("click", () => {
      state.tab = button.dataset.tab;
      render();
    });
  });

  document.querySelectorAll("[data-action]").forEach((button) => {
    button.addEventListener("click", () => handleAction(button.dataset.action));
  });

  document.querySelectorAll("[data-field]").forEach((input) => {
    input.addEventListener("input", () => {
      if (input.dataset.field === "name") state.user.name = input.value || "Guest Golfer";
      if (input.dataset.field === "handicap") state.user.handicap = Number(input.value || 0);
    });
  });
}

function handleAction(action) {
  if (action === "sign-in") {
    state.signedIn = true;
  }
  if (action === "start-round") {
    state.liveRound = {
      index: 0,
      entries: demoCourse.holes.map(() => ({ score: 0, putts: 0, puttsTouched: false }))
    };
  }
  if (action === "prev-hole" && state.liveRound) {
    state.liveRound.index = Math.max(0, state.liveRound.index - 1);
  }
  if (action === "next-hole" && state.liveRound) {
    state.liveRound.index = Math.min(demoCourse.holes.length - 1, state.liveRound.index + 1);
  }
  if (action === "putts-minus" && state.liveRound) {
    const entry = currentEntry();
    entry.putts = Math.max(0, entry.putts - 1);
    entry.puttsTouched = true;
  }
  if (action === "putts-plus" && state.liveRound) {
    const entry = currentEntry();
    entry.putts = Math.min(6, entry.putts + 1);
    entry.puttsTouched = true;
  }
  if (action?.startsWith("score-") && state.liveRound) {
    currentEntry().score = Number(action.replace("score-", ""));
  }
  if (action === "save-hole" && state.liveRound) {
    const entry = currentEntry();
    if (!entry.score) {
      window.alert("Enter a gross score before moving on.");
      return;
    }
    if (!entry.puttsTouched) {
      window.alert("Add putts before moving on. Tap the putts control even if it was 0 putts.");
      return;
    }
    if (state.liveRound.index === demoCourse.holes.length - 1) {
      saveRound();
    } else {
      state.liveRound.index += 1;
    }
  }
  render();
}

function currentEntry() {
  return state.liveRound.entries[state.liveRound.index];
}

function saveRound() {
  const gross = state.liveRound.entries.reduce((sum, entry) => sum + entry.score, 0);
  const putts = state.liveRound.entries.reduce((sum, entry) => sum + entry.putts, 0);
  const stablefordPoints = state.liveRound.entries.reduce((sum, entry, index) => sum + stableford(entry.score, demoCourse.holes[index]), 0);
  state.rounds.unshift({
    course: demoCourse.name,
    gross,
    putts,
    stableford: stablefordPoints,
    date: new Date().toISOString()
  });
  state.liveGame.players[0].points = stablefordPoints;
  state.liveGame.players[0].holes = demoCourse.holes.length;
  state.liveRound = null;
  state.tab = "home";
}

function stableford(score, hole) {
  if (!score) return 0;
  const strokes = demoCourse.courseHandicap / 18 + (hole.si <= demoCourse.courseHandicap % 18 ? 1 : 0);
  const net = score - Math.floor(strokes);
  return Math.max(0, 2 + (hole.par - net));
}

function seasonStats() {
  if (!state.rounds.length) {
    return { gross: "--", stableford: "--", putts: "--", fairways: "--", gir: "--", scramble: "--", penalties: "--" };
  }
  const rounds = state.rounds.length;
  const average = (key) => (state.rounds.reduce((sum, round) => sum + round[key], 0) / rounds).toFixed(1);
  return {
    gross: average("gross"),
    stableford: average("stableford"),
    putts: average("putts"),
    fairways: "42%",
    gir: "49%",
    scramble: "31%",
    penalties: "1.8"
  };
}

function renderLeaderboard() {
  return `
    <div class="leaderboard">
      ${[...state.liveGame.players].sort((a, b) => b.points - a.points).map((player, index) => `
        <div class="leader-row">
          <strong>${index + 1}</strong>
          <span>${player.name}</span>
          <em>${player.holes} holes</em>
          <b>${player.points} pts</b>
        </div>
      `).join("")}
    </div>
  `;
}

function metric(title, value) {
  return `<section class="metric"><span>${title}</span><strong>${value}</strong></section>`;
}

function roundType(title, detail) {
  return `<section class="round-type"><strong>${title}</strong><span>${detail}</span></section>`;
}

function scoreTile(title, value) {
  return `<section><span>${title}</span><strong>${value}</strong></section>`;
}

function scoreButton(score, hole, entry) {
  const labels = ["", "", "Albatross", "Eagle", "Birdie", "Par", "Bogey", "Double"];
  const label = labels[score - hole.par + 5] || "";
  return `<button class="${entry.score === score ? "selected" : ""}" data-action="score-${score}"><strong>${score}</strong><span>${label}</span></button>`;
}

function initials(name) {
  return name.split(" ").map((part) => part[0]).join("").slice(0, 2).toUpperCase();
}

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}

render();
