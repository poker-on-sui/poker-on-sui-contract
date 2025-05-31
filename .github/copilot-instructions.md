# Project Overview: Texas Hold'em Poker Game on SUI Blockchain

This project is a Move smart contract implementation of a Texas Hold'em poker game on the SUI blockchain. The game supports 2-8 players in a session with complete poker functionality including betting rounds, hand evaluation, and pot distribution.

## Technical Requirements

- Move language for SUI blockchain
- Sui Move framework and standard library
- Random number generation for card shuffling
- Event emission for game state tracking
- Comprehensive test coverage

## Move Contract Architecture

- **Main Game Module** (`sources/game.move`): Core poker game logic with player management, betting, and game flow
- **Test Suite** (`tests/game_tests.move`): Comprehensive test coverage for all game scenarios

## Code Style Guidelines

### General Principles

- Use clear, descriptive naming following `snake_case` convention
- Maintain consistent error handling with hex error codes
- Include comprehensive documentation for public functions
- Separate concerns between game logic, validation, and state management

### Move-Specific Patterns

- Use `public entry fun` for functions called by users/frontend
- Use `fun` (private) for internal helper functions
- Mark test-only functions with `#[test_only]`
- Define error constants using hex values (e.g., `const EInvalidPlayer: u64 = 0x0004`)
- Use structured events for state change notifications
- Implement proper validation at function entry points

### Code Organization

- Group related constants at the top of modules
- Define structs before functions that use them
- Place public entry functions before private helper functions
- Use consistent parameter ordering: `game: &mut PokerGame, ctx: &mut TxContext`
- Validate inputs early and fail fast with meaningful error codes

### Testing Standards

- Create comprehensive test scenarios covering edge cases
- Use descriptive test function names indicating what is being tested
- Include both positive and negative test cases with `#[expected_failure]`
- Test multi-player scenarios with different player counts
- Validate all game state transitions and event emissions
