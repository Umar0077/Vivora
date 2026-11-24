import '../domain/ai_models.dart';
import 'ai_provider.dart';

class GeminiSchemas {
  static JsonMap? forFormat(AiOutputFormat format) => switch (format) {
    AiOutputFormat.text || AiOutputFormat.diagnostic => null,
    AiOutputFormat.advice => adviceJsonSchema,
    AiOutputFormat.goals => goalsJsonSchema,
    AiOutputFormat.summary => summaryJsonSchema,
    AiOutputFormat.studyPlan => studyPlanJsonSchema,
  };

  static final JsonMap adviceJsonSchema = JsonSchema.object(
    properties: <String, JsonMap>{
      'recommendations': JsonSchema.array(
        maxItems: 3,
        items: JsonSchema.object(
          properties: <String, JsonMap>{
            'title': JsonSchema.string(
              description: 'Short title, max 80 chars',
            ),
            'description': JsonSchema.string(),
            'category': JsonSchema.enumString(
              enumValues: RecommendationCategory.values
                  .map((c) => c.name)
                  .toList(),
            ),
            'priority': JsonSchema.enumString(
              enumValues: RecommendationPriority.values
                  .map((p) => p.name)
                  .toList(),
            ),
            'reason': JsonSchema.string(
              description: 'Which recorded numbers led to this advice',
            ),
            'sourceMetrics': JsonSchema.array(
              items: JsonSchema.string(),
              description: 'Metric ids from DATA that have data',
            ),
            'suggestion': JsonSchema.string(description: 'One concrete action'),
          },
          propertyOrdering: <String>[
            'title',
            'category',
            'priority',
            'description',
            'reason',
            'sourceMetrics',
            'suggestion',
          ],
        ),
      ),
    },
  );

  static final JsonMap goalsJsonSchema = JsonSchema.object(
    properties: <String, JsonMap>{
      'goalSuggestions': JsonSchema.array(
        maxItems: 3,
        items: JsonSchema.object(
          properties: <String, JsonMap>{
            'goal': JsonSchema.enumString(
              enumValues: SuggestedGoal.values.map((g) => g.name).toList(),
            ),
            'suggestedHours': JsonSchema.number(minimum: 0.5, maximum: 14),
            'reason': JsonSchema.string(),
          },
        ),
      ),
    },
  );

  static final JsonMap summaryJsonSchema = JsonSchema.object(
    properties: <String, JsonMap>{
      'headline': JsonSchema.string(),
      'overview': JsonSchema.string(),
      'highlights': JsonSchema.array(
        maxItems: 4,
        items: JsonSchema.object(
          properties: <String, JsonMap>{
            'label': JsonSchema.string(),
            'text': JsonSchema.string(),
          },
        ),
      ),
      'improvements': JsonSchema.array(items: JsonSchema.string(), maxItems: 3),
      'nextSteps': JsonSchema.array(items: JsonSchema.string(), maxItems: 3),
    },
    propertyOrdering: <String>[
      'headline',
      'overview',
      'highlights',
      'improvements',
      'nextSteps',
    ],
  );

  static final JsonMap studyPlanJsonSchema = JsonSchema.object(
    properties: <String, JsonMap>{
      'overview': JsonSchema.string(),
      'dailyStudyMinutes': JsonSchema.integer(minimum: 15, maximum: 600),
      'sessionsPerDay': JsonSchema.integer(minimum: 1, maximum: 8),
      'sessionMinutes': JsonSchema.integer(minimum: 10, maximum: 90),
      'breakMinutes': JsonSchema.integer(minimum: 3, maximum: 30),
      'priorities': JsonSchema.array(items: JsonSchema.string(), maxItems: 4),
      'goalAlignment': JsonSchema.string(),
      'tips': JsonSchema.array(items: JsonSchema.string(), maxItems: 3),
    },
  );
}

typedef JsonMap = Map<String, dynamic>;

class JsonSchema {
  static JsonMap object({
    required Map<String, JsonMap> properties,
    List<String>? propertyOrdering,
  }) => {
    'type': 'object',
    'properties': properties,
    'required': properties.keys.toList(),
  };
  static JsonMap array({
    required JsonMap items,
    int? maxItems,
    String? description,
  }) => {
    'type': 'array',
    'items': items,
    if (maxItems != null) 'maxItems': maxItems,
    if (description != null) 'description': description,
  };
  static JsonMap string({String? description}) => {
    'type': 'string',
    if (description != null) 'description': description,
  };
  static JsonMap enumString({required List<String> enumValues}) => {
    'type': 'string',
    'enum': enumValues,
  };
  static JsonMap number({num? minimum, num? maximum}) => {
    'type': 'number',
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
  };
  static JsonMap integer({num? minimum, num? maximum}) => {
    ...number(minimum: minimum, maximum: maximum),
    'type': 'integer',
  };
}
