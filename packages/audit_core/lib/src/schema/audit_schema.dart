/// The canonical audit schema.
///
/// Authored once here and rendered into each provider's dialect by
/// transcript_core's [renderSchema] — plain JSON Schema for Anthropic and
/// Ollama, `strict: true` structured outputs for OpenAI, and the OpenAPI subset
/// for Gemini. Nothing else in this package may hand a provider a schema.
///
/// Two constraints shape how this is written, both imposed by OpenAI's strict
/// mode and both cheap to satisfy:
///
///  * every property must appear in its object's `required` list, so optional
///    values are spelled as a nullable type (`["string", "null"]`) rather than
///    by omission; and
///  * every object must carry `additionalProperties: false`, which also stops a
///    chatty model from bolting a `"notes"` field onto the response.
///
/// The Gemini renderer inlines `$ref`, drops `additionalProperties` and turns a
/// nullable union into `nullable: true`, so authoring in the strictest dialect
/// costs nothing there.
library;

/// Descriptions are load-bearing. They travel with the schema into structured
/// output mode, where they are the only instruction the model sees for a field
/// — the system prompt is a long way away by the time it is filling in the
/// four-hundredth token of JSON.
const Map<String, dynamic> auditReportSchema = <String, dynamic>{
  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
  r'$id': 'https://dmg.workshop/schemas/audit-report.json',
  'type': 'object',
  'additionalProperties': false,
  'required': <String>[
    'currency',
    'period_start',
    'period_end',
    'total_net_income',
    'total_expenses',
    'needs',
    'wants',
    'wasteful_leaks',
    'harsh_audit_summary',
    'action_plan',
  ],
  'properties': <String, dynamic>{
    'currency': <String, dynamic>{
      'type': 'string',
      'description':
          'ISO 4217 code of the currency printed on the statement, e.g. GBP, '
              'USD, EUR. Read it from the document; never assume.',
    },
    'period_start': <String, dynamic>{
      'type': 'string',
      'description':
          'First date the statement covers, as YYYY-MM-DD. If the statement '
              'gives only a month, use the first day of that month.',
    },
    'period_end': <String, dynamic>{
      'type': 'string',
      'description':
          'Last date the statement covers, as YYYY-MM-DD. If the statement '
              'gives only a month, use the last day of that month.',
    },
    'total_net_income': <String, dynamic>{
      'type': 'number',
      'description':
          'Every credit that is genuine income — salary after tax, benefits, '
              'refunds of money the user never spent, transfers in from outside '
              'their own accounts. Positive. Exclude transfers between the '
              "user's own accounts and exclude refunds of purchases already "
              'counted as spending, both of which inflate income without a '
              'penny arriving.',
    },
    'total_expenses': <String, dynamic>{
      'type': 'number',
      'description':
          'Every debit in the period, summed. Positive. Must equal the sum of '
              'all needs amounts plus all wants amounts — the two lists '
              'partition spending exhaustively.',
    },
    'needs': <String, dynamic>{
      'type': 'array',
      'description':
          'Spending the user cannot stop this month without material harm: '
              'housing, utilities, insurance, debt minimums, essential '
              'groceries, medication, transport to work, childcare.',
      'items': <String, dynamic>{r'$ref': r'#/$defs/spend_item'},
    },
    'wants': <String, dynamic>{
      'type': 'array',
      'description':
          'Everything else. Discretionary by definition — including the items '
              'also listed under wasteful_leaks.',
      'items': <String, dynamic>{r'$ref': r'#/$defs/spend_item'},
    },
    'wasteful_leaks': <String, dynamic>{
      'type': 'array',
      'description':
          'The subset of spending that is indefensible: money bought nothing '
              'of lasting value, or bought a worse version of something '
              'cheaper. These amounts are ALREADY counted in wants (or '
              'occasionally in an overpriced need) and must not be added to '
              'total_expenses a second time.',
      'items': <String, dynamic>{r'$ref': r'#/$defs/wasteful_leak'},
    },
    'harsh_audit_summary': <String, dynamic>{
      'type': 'string',
      'description':
          'Two to four sentences, second person, blunt and specific. Name the '
              'largest leak and what it costs per year. State the net position '
              'as a fact. No greeting, no encouragement, no hedging, no '
              'suggestion that the user is doing their best.',
    },
    'action_plan': <String, dynamic>{
      'type': 'array',
      'description':
          'Three to seven imperative steps, highest saving first. Each names a '
              'specific amount and a specific thing to stop, cancel or switch. '
              'No generic advice such as "make a budget" or "track your '
              'spending".',
      'items': <String, dynamic>{'type': 'string'},
    },
  },
  r'$defs': <String, dynamic>{
    'spend_item': <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'required': <String>['label', 'amount', 'category', 'evidence'],
      'properties': <String, dynamic>{
        'label': <String, dynamic>{
          'type': 'string',
          'description':
              'The merchant or commitment as the user would name it: "Rent", '
                  '"Deliveroo", "Spotify". Group repeat charges from one '
                  'merchant into a single item.',
        },
        'amount': <String, dynamic>{
          'type': 'number',
          'description':
              'Total for this item across the whole statement period, '
                  'positive, in the statement currency.',
        },
        'category': <String, dynamic>{
          'type': 'string',
          'description':
              'Coarse grouping in lower case: housing, utilities, groceries, '
                  'transport, insurance, debt, health, childcare, eating_out, '
                  'delivery, subscriptions, shopping, entertainment, other.',
        },
        'evidence': <String, dynamic>{r'$ref': r'#/$defs/evidence'},
      },
    },
    'wasteful_leak': <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'required': <String>[
        'label',
        'amount',
        'monthly_equivalent',
        'severity',
        'verdict',
        'evidence',
      ],
      'properties': <String, dynamic>{
        'label': <String, dynamic>{
          'type': 'string',
          'description': 'Merchant or habit, matching its label in wants.',
        },
        'amount': <String, dynamic>{
          'type': 'number',
          'description':
              'Total for this leak across the statement period, positive.',
        },
        'monthly_equivalent': <String, dynamic>{
          'type': 'number',
          'description':
              'What this costs in a typical month. For a recurring charge, the '
                  'recurring amount. For a habit, the period total scaled to 30 '
                  'days. For a genuine one-off, the amount divided across the '
                  'months it should be amortised over — do not annualise a '
                  'single holiday into a monthly haemorrhage.',
        },
        'severity': <String, dynamic>{
          'type': 'string',
          'enum': <String>['minor', 'moderate', 'severe', 'critical'],
          'description':
              'minor: under 1% of net income. moderate: 1-3%. severe: 3-8%, or '
                  'any unused subscription. critical: over 8% of net income, or '
                  'any leak larger than the net surplus, or any leak funded by '
                  'credit while a balance is being carried.',
        },
        'verdict': <String, dynamic>{
          'type': 'string',
          'description':
              'One or two blunt sentences, second person, naming the annual '
                  'cost and what it was bought instead of. This is quoted '
                  'verbatim in the UI. Do not soften it and do not congratulate '
                  'the user for anything.',
        },
        'evidence': <String, dynamic>{r'$ref': r'#/$defs/evidence'},
      },
    },
    'evidence': <String, dynamic>{
      'type': 'object',
      'additionalProperties': false,
      'required': <String>['quote', 'date'],
      'properties': <String, dynamic>{
        'quote': <String, dynamic>{
          'type': 'string',
          'description':
              'A verbatim fragment of one statement line this figure came '
                  'from, copied character for character — merchant string and '
                  'amount as printed. This is checked against the document '
                  'offline; anything not found is shown to the user as '
                  'unverified.',
        },
        'date': <String, dynamic>{
          'type': <String>['string', 'null'],
          'description':
              'Transaction date as YYYY-MM-DD, or null if the line has none.',
        },
      },
    },
  },
};
