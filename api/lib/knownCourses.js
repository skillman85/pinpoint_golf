function hole(number, par, yards, strokeIndex) {
  return { number, par, yards, strokeIndex };
}

export const knownCourses = [
  {
    externalId: "12606",
    favoriteKey: "12606|enville golf club - lodge",
    name: "Enville Golf Club - Lodge",
    clubName: "Enville Golf Club",
    location: "Stourbridge, STS, United Kingdom",
    latitude: 52.4647,
    longitude: -2.2465,
    distance: "Stourbridge",
    source: "known",
    tees: [
      {
        name: "White",
        yards: 6451,
        par: 71,
        slope: 138,
        rating: 72.2,
        holes: [
          hole(1, 3, 181, 1), hole(2, 4, 371, 2), hole(3, 4, 321, 3),
          hole(4, 4, 415, 4), hole(5, 4, 294, 5), hole(6, 4, 408, 6),
          hole(7, 5, 511, 7), hole(8, 3, 187, 8), hole(9, 4, 397, 9),
          hole(10, 5, 516, 10), hole(11, 4, 405, 11), hole(12, 4, 427, 12),
          hole(13, 4, 415, 13), hole(14, 4, 353, 14), hole(15, 4, 391, 15),
          hole(16, 4, 354, 16), hole(17, 3, 157, 17), hole(18, 4, 348, 18)
        ]
      },
      {
        name: "Yellow",
        yards: 6237,
        par: 71,
        slope: 135,
        rating: 71.0,
        holes: [
          hole(1, 3, 168, 1), hole(2, 4, 365, 2), hole(3, 4, 316, 3),
          hole(4, 4, 407, 4), hole(5, 4, 273, 5), hole(6, 4, 401, 6),
          hole(7, 5, 500, 7), hole(8, 3, 165, 8), hole(9, 4, 379, 9),
          hole(10, 5, 497, 10), hole(11, 4, 398, 11), hole(12, 4, 408, 12),
          hole(13, 4, 409, 13), hole(14, 4, 334, 14), hole(15, 4, 382, 15),
          hole(16, 4, 348, 16), hole(17, 3, 155, 17), hole(18, 4, 332, 18)
        ]
      }
    ]
  },
  {
    externalId: "12756",
    favoriteKey: "12756|enville golf club - highgate",
    name: "Enville Golf Club - Highgate",
    clubName: "Enville Golf Club",
    location: "Stourbridge, STS, United Kingdom",
    latitude: 52.4647,
    longitude: -2.2465,
    distance: "Stourbridge",
    source: "known",
    tees: [
      {
        name: "White",
        yards: 6701,
        par: 71,
        slope: 137,
        rating: 73.7,
        holes: [
          hole(1, 4, 468, 1), hole(2, 3, 214, 2), hole(3, 4, 317, 3),
          hole(4, 4, 363, 4), hole(5, 3, 163, 5), hole(6, 4, 448, 6),
          hole(7, 4, 322, 7), hole(8, 4, 392, 8), hole(9, 5, 597, 9),
          hole(10, 5, 506, 10), hole(11, 4, 383, 11), hole(12, 4, 424, 12),
          hole(13, 4, 442, 13), hole(14, 3, 154, 14), hole(15, 4, 395, 15),
          hole(16, 3, 214, 16), hole(17, 4, 389, 17), hole(18, 5, 510, 18)
        ]
      },
      {
        name: "Yellow",
        yards: 6483,
        par: 71,
        slope: 137,
        rating: 72.7,
        holes: [
          hole(1, 4, 461, 1), hole(2, 3, 207, 2), hole(3, 4, 310, 3),
          hole(4, 4, 358, 4), hole(5, 3, 158, 5), hole(6, 4, 430, 6),
          hole(7, 4, 318, 7), hole(8, 4, 361, 8), hole(9, 5, 588, 9),
          hole(10, 5, 476, 10), hole(11, 4, 355, 11), hole(12, 4, 408, 12),
          hole(13, 4, 435, 13), hole(14, 3, 140, 14), hole(15, 4, 384, 15),
          hole(16, 3, 206, 16), hole(17, 4, 382, 17), hole(18, 5, 506, 18)
        ]
      }
    ]
  }
];

export function searchKnownCourses(query, limit = 8) {
  const terms = `${query}`.toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return [];

  return knownCourses
    .filter((course) => {
      const haystack = [course.name, course.clubName, course.location, course.distance].join(" ").toLowerCase();
      return terms.every((term) => haystack.includes(term));
    })
    .slice(0, Math.min(Math.max(limit, 1), 12));
}
