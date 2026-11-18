#if DEBUG
import Foundation

/// A small A1 seed for trying practice before the real word lists are bundled, and the fixture
/// of the unit tests. Debug builds only; loaded from the Database lab tab. Its keys carry a
/// `dbg_` prefix so they never clash with the keys of the Goethe seeds.
nonisolated enum DebugSeed {
    static let id = "debug_a1"

    static var data: Data { Data(json.utf8) }

    static let json = """
{
 "seed": {
  "id": "debug_a1",
  "title": "Debug A1",
  "level": "A1",
  "version": 1
 },
 "entries": [
  {
   "key": "a1.dbg_abfahren",
   "headword": "abfahren",
   "lemma": "abfahren",
   "pos": "VERB",
   "gender": null,
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_uhr",
   "headword": "die Uhr, -en",
   "lemma": "Uhr",
   "pos": "NOUN",
   "gender": "Fem",
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_luft",
   "headword": "die Luft",
   "lemma": "Luft",
   "pos": "NOUN",
   "gender": "Fem",
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_luegen",
   "headword": "lügen, lügt, log, hat gelogen",
   "lemma": "lügen",
   "pos": "VERB",
   "gender": null,
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_luege",
   "headword": "die Lüge, -n",
   "lemma": "Lüge",
   "pos": "NOUN",
   "gender": "Fem",
   "group": null,
   "region": null,
   "parent": "a1.dbg_luegen"
  },
  {
   "key": "a1.dbg_rauchen",
   "headword": "rauchen",
   "lemma": "rauchen",
   "pos": "VERB",
   "gender": null,
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_manchmal",
   "headword": "manchmal",
   "lemma": "manchmal",
   "pos": "ADV",
   "gender": null,
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_rot",
   "headword": "rot",
   "lemma": "rot",
   "pos": "ADJ",
   "gender": null,
   "group": "Farben",
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_parkieren",
   "headword": "parkieren (CH) → D, A: parken",
   "lemma": "parkieren",
   "pos": "VERB",
   "gender": null,
   "group": null,
   "region": "CH",
   "parent": null
  },
  {
   "key": "a1.dbg_kaffee",
   "headword": "der Kaffee",
   "lemma": "Kaffee",
   "pos": "NOUN",
   "gender": "Masc",
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_bahnhof",
   "headword": "der Bahnhof, ¨-e",
   "lemma": "Bahnhof",
   "pos": "NOUN",
   "gender": "Masc",
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_helfen",
   "headword": "helfen, hilft, half, hat geholfen",
   "lemma": "helfen",
   "pos": "VERB",
   "gender": null,
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_wochenende",
   "headword": "das Wochenende, -n",
   "lemma": "Wochenende",
   "pos": "NOUN",
   "gender": "Neut",
   "group": null,
   "region": null,
   "parent": null
  },
  {
   "key": "a1.dbg_kosten",
   "headword": "kosten",
   "lemma": "kosten",
   "pos": "VERB",
   "gender": null,
   "group": null,
   "region": null,
   "parent": null
  }
 ],
 "sentences": [
  {
   "key": "a1.dbg_abfahren.1",
   "source": "goethe",
   "de": "Wir fahren um 12 Uhr ab.",
   "spoken": "Wir fahren um zwölf Uhr ab.",
   "translations": {
    "zh": "我们十二点出发。",
    "en": "We leave at twelve o'clock."
   },
   "words": [
    [
     "Wir",
     "wir",
     "PRON",
     "Nom"
    ],
    [
     "fahren",
     "abfahren",
     "VERB",
     "Fin"
    ],
    [
     "um",
     "um",
     "ADP",
     "Acc"
    ],
    [
     "12",
     "zwölf",
     "NUM",
     ""
    ],
    [
     "Uhr",
     "Uhr",
     "NOUN",
     "Acc",
     "Fem"
    ],
    [
     "ab",
     "abfahren",
     "PART",
     ""
    ],
    [
     ".",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Subj",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      1,
      5
     ]
    },
    {
     "fn": "AdvT",
     "tokens": [
      2,
      3,
      4
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_abfahren",
     "tokens": [
      1,
      5
     ]
    },
    {
     "key": "a1.dbg_uhr",
     "tokens": [
      4
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_luft.1",
   "source": "goethe",
   "de": "Die Seeluft tut mir gut.",
   "spoken": null,
   "translations": {
    "zh": "海边的空气对我有好处。",
    "en": "The sea air does me good."
   },
   "words": [
    [
     "Die",
     "der",
     "DET",
     "Nom"
    ],
    [
     "Seeluft",
     "Seeluft",
     "NOUN",
     "Nom",
     "Fem"
    ],
    [
     "tut",
     "tun",
     "VERB",
     "Fin"
    ],
    [
     "mir",
     "ich",
     "PRON",
     "Dat"
    ],
    [
     "gut",
     "gut",
     "ADJ",
     ""
    ],
    [
     ".",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Subj",
     "tokens": [
      0,
      1
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      2
     ]
    },
    {
     "fn": "ObjDat",
     "tokens": [
      3
     ]
    },
    {
     "fn": "AdvM",
     "tokens": [
      4
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_luft",
     "tokens": [
      1
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_luegen.1",
   "source": "goethe",
   "de": "Du sollst nicht lügen.",
   "spoken": null,
   "translations": {
    "zh": "你不应该说谎。",
    "en": "You should not lie."
   },
   "words": [
    [
     "Du",
     "du",
     "PRON",
     "Nom"
    ],
    [
     "sollst",
     "sollen",
     "AUX",
     "Fin"
    ],
    [
     "nicht",
     "nicht",
     "PART",
     ""
    ],
    [
     "lügen",
     "lügen",
     "VERB",
     "Inf"
    ],
    [
     ".",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Subj",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      1,
      3
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_luegen",
     "tokens": [
      3
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_luege.1",
   "source": "goethe",
   "de": "Das ist eine Lüge!",
   "spoken": null,
   "translations": {
    "zh": "这是谎话！",
    "en": "That is a lie!"
   },
   "words": [
    [
     "Das",
     "das",
     "PRON",
     "Nom"
    ],
    [
     "ist",
     "sein",
     "AUX",
     "Fin"
    ],
    [
     "eine",
     "ein",
     "DET",
     "Nom"
    ],
    [
     "Lüge",
     "Lüge",
     "NOUN",
     "Nom",
     "Fem"
    ],
    [
     "!",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Subj",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      1
     ]
    },
    {
     "fn": "PredC",
     "tokens": [
      2,
      3
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_luege",
     "tokens": [
      3
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_rauchen.1",
   "source": "goethe",
   "de": "Rauchen Sie? – Manchmal.",
   "spoken": null,
   "translations": {
    "zh": "您抽烟吗？——有时候。",
    "en": "Do you (formal) smoke? – Sometimes."
   },
   "words": [
    [
     "Rauchen",
     "rauchen",
     "VERB",
     "Fin"
    ],
    [
     "Sie",
     "Sie",
     "PRON",
     "Nom"
    ],
    [
     "?",
     "",
     "PUNCT",
     ""
    ],
    [
     "–",
     "",
     "PUNCT",
     ""
    ],
    [
     "Manchmal",
     "manchmal",
     "ADV",
     ""
    ],
    [
     ".",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Pred",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Subj",
     "tokens": [
      1
     ]
    },
    {
     "fn": "AdvT",
     "tokens": [
      4
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_rauchen",
     "tokens": [
      0
     ]
    },
    {
     "key": "a1.dbg_manchmal",
     "tokens": [
      4
     ]
    }
   ],
   "orig": "Rauchen Sie? / – Manchmal."
  },
  {
   "key": "a1.dbg_rot.1",
   "source": "generated",
   "de": "Das Auto ist rot.",
   "spoken": null,
   "translations": {
    "zh": "这辆车是红色的。",
    "en": "The car is red."
   },
   "words": [
    [
     "Das",
     "der",
     "DET",
     "Nom"
    ],
    [
     "Auto",
     "Auto",
     "NOUN",
     "Nom",
     "Neut"
    ],
    [
     "ist",
     "sein",
     "AUX",
     "Fin"
    ],
    [
     "rot",
     "rot",
     "ADJ",
     ""
    ],
    [
     ".",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Subj",
     "tokens": [
      0,
      1
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      2
     ]
    },
    {
     "fn": "PredC",
     "tokens": [
      3
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_rot",
     "tokens": [
      3
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_parkieren.1",
   "source": "goethe",
   "de": "Hier dürfen Sie nicht parkieren.",
   "spoken": null,
   "translations": {
    "zh": "您不能在这里停车。",
    "en": "You (formal) may not park here."
   },
   "words": [
    [
     "Hier",
     "hier",
     "ADV",
     ""
    ],
    [
     "dürfen",
     "dürfen",
     "AUX",
     "Fin"
    ],
    [
     "Sie",
     "Sie",
     "PRON",
     "Nom"
    ],
    [
     "nicht",
     "nicht",
     "PART",
     ""
    ],
    [
     "parkieren",
     "parkieren",
     "VERB",
     "Inf"
    ],
    [
     ".",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "AdvL",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      1,
      4
     ]
    },
    {
     "fn": "Subj",
     "tokens": [
      2
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_parkieren",
     "tokens": [
      4
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_kaffee.1",
   "source": "goethe",
   "de": "Ich trinke gern Kaffee.",
   "spoken": null,
   "translations": {
    "zh": "我喜欢喝咖啡。",
    "en": "I like drinking coffee."
   },
   "words": [
    [
     "Ich",
     "ich",
     "PRON",
     "Nom"
    ],
    [
     "trinke",
     "trinken",
     "VERB",
     "Fin"
    ],
    [
     "gern",
     "gern",
     "ADV",
     ""
    ],
    [
     "Kaffee",
     "Kaffee",
     "NOUN",
     "Acc",
     "Masc"
    ],
    [
     ".",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Subj",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      1
     ]
    },
    {
     "fn": "AdvM",
     "tokens": [
      2
     ]
    },
    {
     "fn": "ObjAcc",
     "tokens": [
      3
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_kaffee",
     "tokens": [
      3
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_bahnhof.1",
   "source": "goethe",
   "de": "Wo ist der Bahnhof?",
   "spoken": null,
   "translations": {
    "zh": "火车站在哪里？",
    "en": "Where is the train station?"
   },
   "words": [
    [
     "Wo",
     "wo",
     "ADV",
     ""
    ],
    [
     "ist",
     "sein",
     "AUX",
     "Fin"
    ],
    [
     "der",
     "der",
     "DET",
     "Nom"
    ],
    [
     "Bahnhof",
     "Bahnhof",
     "NOUN",
     "Nom",
     "Masc"
    ],
    [
     "?",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "AdvL",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      1
     ]
    },
    {
     "fn": "Subj",
     "tokens": [
      2,
      3
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_bahnhof",
     "tokens": [
      3
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_helfen.1",
   "source": "goethe",
   "de": "Kannst du mir helfen?",
   "spoken": null,
   "translations": {
    "zh": "你能帮我吗？",
    "en": "Can you (informal) help me?"
   },
   "words": [
    [
     "Kannst",
     "können",
     "AUX",
     "Fin"
    ],
    [
     "du",
     "du",
     "PRON",
     "Nom"
    ],
    [
     "mir",
     "ich",
     "PRON",
     "Dat"
    ],
    [
     "helfen",
     "helfen",
     "VERB",
     "Inf"
    ],
    [
     "?",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Pred",
     "tokens": [
      0,
      3
     ]
    },
    {
     "fn": "Subj",
     "tokens": [
      1
     ]
    },
    {
     "fn": "ObjDat",
     "tokens": [
      2
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_helfen",
     "tokens": [
      3
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_wochenende.1",
   "source": "goethe",
   "de": "Was machst du am Wochenende?",
   "spoken": null,
   "translations": {
    "zh": "你周末做什么？",
    "en": "What are you (informal) doing at the weekend?"
   },
   "words": [
    [
     "Was",
     "was",
     "PRON",
     "Acc"
    ],
    [
     "machst",
     "machen",
     "VERB",
     "Fin"
    ],
    [
     "du",
     "du",
     "PRON",
     "Nom"
    ],
    [
     "am",
     "an",
     "ADP",
     "Dat"
    ],
    [
     "Wochenende",
     "Wochenende",
     "NOUN",
     "Dat",
     "Neut"
    ],
    [
     "?",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "ObjAcc",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      1
     ]
    },
    {
     "fn": "Subj",
     "tokens": [
      2
     ]
    },
    {
     "fn": "AdvT",
     "tokens": [
      3,
      4
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_wochenende",
     "tokens": [
      4
     ]
    }
   ],
   "orig": null
  },
  {
   "key": "a1.dbg_kosten.1",
   "source": "goethe",
   "de": "Das kostet 20 Euro.",
   "spoken": "Das kostet zwanzig Euro.",
   "translations": {
    "zh": "这个二十欧元。",
    "en": "That costs twenty euros."
   },
   "words": [
    [
     "Das",
     "das",
     "PRON",
     "Nom"
    ],
    [
     "kostet",
     "kosten",
     "VERB",
     "Fin"
    ],
    [
     "20",
     "zwanzig",
     "NUM",
     ""
    ],
    [
     "Euro",
     "Euro",
     "NOUN",
     "Acc",
     "Masc"
    ],
    [
     ".",
     "",
     "PUNCT",
     ""
    ]
   ],
   "spans": [
    {
     "fn": "Subj",
     "tokens": [
      0
     ]
    },
    {
     "fn": "Pred",
     "tokens": [
      1
     ]
    },
    {
     "fn": "ObjAcc",
     "tokens": [
      2,
      3
     ]
    }
   ],
   "entries": [
    {
     "key": "a1.dbg_kosten",
     "tokens": [
      1
     ]
    }
   ],
   "orig": null
  }
 ]
}
"""
}
#endif
