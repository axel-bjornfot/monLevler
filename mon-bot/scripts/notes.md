# Bot Research Notes

## Confirmed
- mGBA scripting works
- Script loads correctly
- Frame callback works

## Need to find
- Overworld vs battle state
- Wild vs trainer battle
- Map ID
- X/Y position
- Lead Pokemon HP
- Move PP
- Enemy species

## Tests
- Test 1:
  Standing in Pokemon Center

- Test 2:
  Walking in overworld

- Test 3:
  Wild battle start


  Confirmed player coordinates

Primary addresses:
X = 0x02037360
Y = 0x02037362

Behavior:
- East increases X
- West decreases X
- South increases Y
- North decreases Y

Important:
- During map transitions, coordinates can briefly become 0,0
- Coordinates must always be used together with map ID


infront of healer in pokecenter
Map: 15 | X: 10 | Y: 11
down to
Map: 15 | X: 10 | Y: 15
right to
Map: 15 | X: 16 | Y: 15
down to
Map: 15 | X: 25| Y: 24
right to
Map: 15 | X: 32| Y: 24
down to
Map: 15 | X: 32| Y: 35
left to (entance)
Map: 15 | X: 25| Y: 35
up to (inside victory road)
Map: 70 | X: 46| Y: 12