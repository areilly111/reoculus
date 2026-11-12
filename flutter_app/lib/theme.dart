import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// DESIGN DIRECTIONS
// PICKED 2026-11-12: C Dark VR Neon, blue instead of purple .
// That is the default (see AppState). A and B are untouched and still
// switchable in Setup. The app reads the active direction from AppState
// and every screen is built from these tokens, so switching is one setting.
// ---------------------------------------------------------------------------

enum DesignDirection { proDark, lightFriendly, vrNeon }

extension DesignDirectionInfo on DesignDirection {
  String get id {
    switch (this) {
      case DesignDirection.proDark: return 'pro-dark';
      case DesignDirection.lightFriendly: return 'light-friendly';
      case DesignDirection.vrNeon: return 'vr-neon';
    }
  }

  String get name {
    switch (this) {
      case DesignDirection.proDark: return 'Clean Dark Pro';
      case DesignDirection.lightFriendly: return 'Light Friendly Simple';
      case DesignDirection.vrNeon: return 'Dark VR Neon';
    }
  }

  String get tagline {
    switch (this) {
      case DesignDirection.proDark: return 'Calm, professional, easy on the eyes for long sessions.';
      case DesignDirection.lightFriendly: return 'Bright, warm and extra clear. The easiest to read.';
      case DesignDirection.vrNeon: return 'Dark with glowing VR accents. Feels like a headset app.';
    }
  }

  String get plainDescription {
    switch (this) {
      case DesignDirection.proDark:
        return 'Dark charcoal background, soft white text, one calm blue accent for buttons. '
            'Cards are quiet and spaced out, headings are clear, nothing shouts. '
            'Suits: everyday use, long sessions, a tool that feels like a proper desktop app.';
      case DesignDirection.lightFriendly:
        return 'White and very light grey background, dark text, large type, green accent for '
            'safe actions and blue for main buttons. Lots of white space and big touch targets. '
            'Suits: first-time users, bright rooms, anyone who wants the clearest reading.';
      case DesignDirection.vrNeon:
        return 'Near-black background, glowing bright blue and cyan accents, rounded cards with a '
            'soft blue glow around the connected headset card. Same layout as the others, more energy. '
            'Suits: people who like the VR look, evening use, showing the app to friends.';
    }
  }
}

class AppTheme {
  static ThemeData themeFor(DesignDirection d) {
    switch (d) {
      case DesignDirection.lightFriendly:
        return ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB), brightness: Brightness.light),
          scaffoldBackgroundColor: const Color(0xFFF6F7F9),
          cardTheme: CardThemeData(
            color: Colors.white,
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF6F7F9), foregroundColor: Color(0xFF111827), elevation: 0),
          textTheme: const TextTheme(
            headlineSmall: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
            titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
            titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
            bodyMedium: TextStyle(fontSize: 16, color: Color(0xFF374151)),
            bodySmall: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
          ),
        );
      case DesignDirection.vrNeon:
        return ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: const ColorScheme.dark(
            // Picked 2026-11-12: blue, not purple. Primary bright blue,
            // secondary cyan, surfaces near-black with a blue tint.
            primary: Color(0xFF38BDF8),
            secondary: Color(0xFF22D3EE),
            surface: Color(0xFF101A2E),
            onSurface: Color(0xFFF1F5F9),
          ),
          scaffoldBackgroundColor: const Color(0xFF070B14),
          cardTheme: CardThemeData(
            color: const Color(0xFF111E33),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF070B14), foregroundColor: Color(0xFFF1F5F9), elevation: 0),
          textTheme: const TextTheme(
            headlineSmall: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Color(0xFFF1F5F9)),
            titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFFF1F5F9)),
            titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFFF1F5F9)),
            bodyMedium: TextStyle(fontSize: 16, color: Color(0xFFCBD5E1)),
            bodySmall: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
          ),
        );
      case DesignDirection.proDark:
        return ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B82F6), brightness: Brightness.dark),
          scaffoldBackgroundColor: const Color(0xFF111417),
          cardTheme: CardThemeData(
            color: const Color(0xFF1B1F23),
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF111417), foregroundColor: Colors.white, elevation: 0),
          textTheme: const TextTheme(
            headlineSmall: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Colors.white),
            titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
            titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
            bodyMedium: TextStyle(fontSize: 16, color: Color(0xFFD1D5DB)),
            bodySmall: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
          ),
        );
    }
  }

  static Color accentFor(DesignDirection d) {
    switch (d) {
      case DesignDirection.proDark: return const Color(0xFF3B82F6);
      case DesignDirection.lightFriendly: return const Color(0xFF2563EB);
      case DesignDirection.vrNeon: return const Color(0xFF38BDF8);
    }
  }
}
