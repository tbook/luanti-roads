-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real towns_api v1 settlement records, as published by the neighbouring Towns
-- mod and recorded by its own tools/roads_api_demo run (seed 2014, three medieval
-- settlements, 14 exits: wall gatehouses, posterns and openings, flat and graded).
-- The data is verbatim producer output (every exit was matched against the built
-- nodes by that tool); only its Lua spelling is new. Used to test Roads' provider
-- and arrival geometry against real exit shapes without loading Towns.
return {
  {
    id = "auto:1:-1",
    center = {
      x = 1535,
      y = 6,
      z = -335
    },
    core = {
      x1 = 1457,
      x2 = 1668,
      z1 = -440,
      z2 = -288
    },
    exits = {
      {
        id = "+x:1614:-304",
        columns = {
          {
            x = 1614,
            z = -304
          },
          {
            x = 1614,
            z = -303
          }
        },
        direction = {
          x = 1,
          z = 0
        },
        length = 9,
        profile = {
          {
            y = 6,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 6,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 7,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 7,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 8,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          },
          {
            y = 9,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          },
          {
            y = 10,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          },
          {
            y = 11,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 11,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_opening"
      },
      {
        id = "+x:1616:-366",
        columns = {
          {
            x = 1616,
            z = -366
          },
          {
            x = 1616,
            z = -365
          }
        },
        direction = {
          x = 1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 6,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 5,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 4,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 3,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          }
        },
        source = "wall_postern"
      },
      {
        id = "+z:1534:-282",
        columns = {
          {
            x = 1534,
            z = -282
          },
          {
            x = 1535,
            z = -282
          },
          {
            x = 1536,
            z = -282
          },
          {
            x = 1537,
            z = -282
          }
        },
        direction = {
          x = 0,
          z = 1
        },
        length = 4,
        profile = {
          {
            y = 7,
            name = "mcl_stairs:stair_cobble",
            param2 = 0
          },
          {
            y = 8,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 8,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 8,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_gatehouse"
      },
      {
        id = "-x:1451:-336",
        columns = {
          {
            x = 1451,
            z = -336
          },
          {
            x = 1451,
            z = -335
          },
          {
            x = 1451,
            z = -334
          },
          {
            x = 1451,
            z = -333
          }
        },
        direction = {
          x = -1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 7,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 8,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 9,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 9,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_gatehouse"
      },
      {
        id = "-x:1455:-304",
        columns = {
          {
            x = 1455,
            z = -304
          },
          {
            x = 1455,
            z = -303
          }
        },
        direction = {
          x = -1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 7,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 8,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 8,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 8,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_postern"
      }
    },
    reservation = {
      max = {
        x = 1780,
        y = 148,
        z = -90
      },
      min = {
        x = 1290,
        y = -121,
        z = -580
      }
    },
    site_id = "2:1:-1:7:medieval:341296873:1535:-335",
    state = "complete",
    structures = {
      {
        x1 = 1410,
        x2 = 1417,
        z1 = -424,
        z2 = -416
      },
      {
        x1 = 1413,
        x2 = 1429,
        z1 = -394,
        z2 = -386
      },
      {
        x1 = 1434,
        x2 = 1446,
        z1 = -345,
        z2 = -329
      },
      {
        x1 = 1443,
        x2 = 1459,
        z1 = -278,
        z2 = -266
      },
      {
        x1 = 1452,
        x2 = 1460,
        z1 = -342,
        z2 = -327
      },
      {
        x1 = 1454,
        x2 = 1461,
        z1 = -384,
        z2 = -377
      },
      {
        x1 = 1454,
        x2 = 1461,
        z1 = -292,
        z2 = -285
      },
      {
        x1 = 1456,
        x2 = 1458,
        z1 = -306,
        z2 = -297
      },
      {
        x1 = 1470,
        x2 = 1486,
        z1 = -461,
        z2 = -449
      },
      {
        x1 = 1480,
        x2 = 1486,
        z1 = -291,
        z2 = -285
      },
      {
        x1 = 1498,
        x2 = 1514,
        z1 = -279,
        z2 = -267
      },
      {
        x1 = 1506,
        x2 = 1512,
        z1 = -291,
        z2 = -285
      },
      {
        x1 = 1510,
        x2 = 1518,
        z1 = -477,
        z2 = -470
      },
      {
        x1 = 1512,
        x2 = 1519,
        z1 = -443,
        z2 = -436
      },
      {
        x1 = 1518,
        x2 = 1526,
        z1 = -240,
        z2 = -233
      },
      {
        x1 = 1528,
        x2 = 1543,
        z1 = -291,
        z2 = -283
      },
      {
        x1 = 1541,
        x2 = 1547,
        z1 = -443,
        z2 = -437
      },
      {
        x1 = 1549,
        x2 = 1565,
        z1 = -463,
        z2 = -451
      },
      {
        x1 = 1553,
        x2 = 1569,
        z1 = -278,
        z2 = -266
      },
      {
        x1 = 1560,
        x2 = 1566,
        z1 = -291,
        z2 = -285
      },
      {
        x1 = 1567,
        x2 = 1574,
        z1 = -443,
        z2 = -436
      },
      {
        x1 = 1586,
        x2 = 1592,
        z1 = -291,
        z2 = -285
      },
      {
        x1 = 1592,
        x2 = 1608,
        z1 = -462,
        z2 = -450
      },
      {
        x1 = 1610,
        x2 = 1617,
        z1 = -292,
        z2 = -285
      },
      {
        x1 = 1622,
        x2 = 1638,
        z1 = -277,
        z2 = -265
      },
      {
        x1 = 1664,
        x2 = 1671,
        z1 = -363,
        z2 = -356
      },
      {
        x1 = 1664,
        x2 = 1671,
        z1 = -313,
        z2 = -306
      },
      {
        x1 = 1665,
        x2 = 1671,
        z1 = -337,
        z2 = -331
      },
      {
        x1 = 1672,
        x2 = 1679,
        z1 = -265,
        z2 = -257
      },
      {
        x1 = 1679,
        x2 = 1691,
        z1 = -304,
        z2 = -288
      },
      {
        x1 = 1707,
        x2 = 1714,
        z1 = -240,
        z2 = -232
      }
    },
    town_type = "medieval"
  },
  {
    id = "auto:1:-2",
    center = {
      x = 1362,
      y = 4,
      z = -1722
    },
    core = {
      x1 = 1283,
      x2 = 1494,
      z1 = -1769,
      z2 = -1617
    },
    exits = {
      {
        id = "+x:1442:-1754",
        columns = {
          {
            x = 1442,
            z = -1754
          },
          {
            x = 1442,
            z = -1753
          }
        },
        direction = {
          x = 1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 5,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          },
          {
            y = 6,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 6,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 6,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_postern"
      },
      {
        id = "-x:1281:-1692",
        columns = {
          {
            x = 1281,
            z = -1692
          },
          {
            x = 1281,
            z = -1691
          }
        },
        direction = {
          x = -1,
          z = 0
        },
        length = 5,
        profile = {
          {
            y = 5,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 6,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 7,
            name = "mcl_stairs:stair_cobble",
            param2 = 3
          },
          {
            y = 8,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 8,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_postern"
      },
      {
        id = "-z:1360:-1775",
        columns = {
          {
            x = 1360,
            z = -1775
          },
          {
            x = 1361,
            z = -1775
          },
          {
            x = 1362,
            z = -1775
          },
          {
            x = 1363,
            z = -1775
          }
        },
        direction = {
          x = 0,
          z = -1
        },
        length = 4,
        profile = {
          {
            y = 5,
            name = "mcl_stairs:stair_cobble",
            param2 = 2
          },
          {
            y = 6,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 6,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 6,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_gatehouse"
      }
    },
    reservation = {
      max = {
        x = 1607,
        y = 146,
        z = -1477
      },
      min = {
        x = 1117,
        y = -123,
        z = -1967
      }
    },
    site_id = "2:1:-2:0:medieval:640708959:1362:-1722",
    state = "complete",
    structures = {
      {
        x1 = 1235,
        x2 = 1242,
        z1 = -1709,
        z2 = -1701
      },
      {
        x1 = 1237,
        x2 = 1244,
        z1 = -1769,
        z2 = -1761
      },
      {
        x1 = 1260,
        x2 = 1272,
        z1 = -1672,
        z2 = -1656
      },
      {
        x1 = 1260,
        x2 = 1272,
        z1 = -1632,
        z2 = -1616
      },
      {
        x1 = 1280,
        x2 = 1287,
        z1 = -1772,
        z2 = -1765
      },
      {
        x1 = 1280,
        x2 = 1287,
        z1 = -1680,
        z2 = -1673
      },
      {
        x1 = 1282,
        x2 = 1284,
        z1 = -1694,
        z2 = -1685
      },
      {
        x1 = 1312,
        x2 = 1328,
        z1 = -1790,
        z2 = -1778
      },
      {
        x1 = 1323,
        x2 = 1330,
        z1 = -1621,
        z2 = -1614
      },
      {
        x1 = 1332,
        x2 = 1338,
        z1 = -1772,
        z2 = -1766
      },
      {
        x1 = 1352,
        x2 = 1358,
        z1 = -1620,
        z2 = -1614
      },
      {
        x1 = 1354,
        x2 = 1369,
        z1 = -1774,
        z2 = -1766
      },
      {
        x1 = 1361,
        x2 = 1377,
        z1 = -1792,
        z2 = -1780
      },
      {
        x1 = 1378,
        x2 = 1385,
        z1 = -1621,
        z2 = -1614
      },
      {
        x1 = 1386,
        x2 = 1392,
        z1 = -1772,
        z2 = -1766
      },
      {
        x1 = 1401,
        x2 = 1417,
        z1 = -1606,
        z2 = -1594
      },
      {
        x1 = 1409,
        x2 = 1416,
        z1 = -1825,
        z2 = -1817
      },
      {
        x1 = 1412,
        x2 = 1418,
        z1 = -1772,
        z2 = -1766
      },
      {
        x1 = 1424,
        x2 = 1440,
        z1 = -1791,
        z2 = -1779
      },
      {
        x1 = 1436,
        x2 = 1443,
        z1 = -1772,
        z2 = -1765
      },
      {
        x1 = 1447,
        x2 = 1454,
        z1 = -1572,
        z2 = -1564
      },
      {
        x1 = 1466,
        x2 = 1482,
        z1 = -1790,
        z2 = -1778
      },
      {
        x1 = 1490,
        x2 = 1497,
        z1 = -1751,
        z2 = -1744
      },
      {
        x1 = 1490,
        x2 = 1497,
        z1 = -1701,
        z2 = -1694
      },
      {
        x1 = 1491,
        x2 = 1497,
        z1 = -1725,
        z2 = -1719
      },
      {
        x1 = 1501,
        x2 = 1517,
        z1 = -1606,
        z2 = -1594
      },
      {
        x1 = 1503,
        x2 = 1515,
        z1 = -1753,
        z2 = -1737
      },
      {
        x1 = 1503,
        x2 = 1515,
        z1 = -1642,
        z2 = -1626
      },
      {
        x1 = 1504,
        x2 = 1516,
        z1 = -1694,
        z2 = -1678
      },
      {
        x1 = 1518,
        x2 = 1525,
        z1 = -1808,
        z2 = -1800
      }
    },
    town_type = "medieval"
  },
  {
    id = "auto:-2:-2",
    center = {
      x = -1710,
      y = 10,
      z = -1716
    },
    core = {
      x1 = -1788,
      x2 = -1577,
      z1 = -1821,
      z2 = -1669
    },
    exits = {
      {
        id = "+x:-1629:-1747",
        columns = {
          {
            x = -1629,
            z = -1747
          },
          {
            x = -1629,
            z = -1746
          }
        },
        direction = {
          x = 1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 11,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          },
          {
            y = 12,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 12,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 12,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_postern"
      },
      {
        id = "+x:-1631:-1685",
        columns = {
          {
            x = -1631,
            z = -1685
          },
          {
            x = -1631,
            z = -1684
          }
        },
        direction = {
          x = 1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 10,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 10,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 10,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 10,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_opening"
      },
      {
        id = "+z:-1711:-1663",
        columns = {
          {
            x = -1711,
            z = -1663
          },
          {
            x = -1710,
            z = -1663
          },
          {
            x = -1709,
            z = -1663
          },
          {
            x = -1708,
            z = -1663
          }
        },
        direction = {
          x = 0,
          z = 1
        },
        length = 4,
        profile = {
          {
            y = 10,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 10,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 10,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 10,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_gatehouse"
      },
      {
        id = "-x:-1790:-1685",
        columns = {
          {
            x = -1790,
            z = -1685
          },
          {
            x = -1790,
            z = -1684
          }
        },
        direction = {
          x = -1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 11,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 11,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 11,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 11,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_postern"
      },
      {
        id = "-x:-1790:-1747",
        columns = {
          {
            x = -1790,
            z = -1747
          },
          {
            x = -1790,
            z = -1746
          }
        },
        direction = {
          x = -1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 10,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          },
          {
            y = 9,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          },
          {
            y = 8,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          },
          {
            y = 7,
            name = "mcl_stairs:stair_cobble",
            param2 = 1
          }
        },
        source = "wall_postern"
      },
      {
        id = "-x:-1794:-1717",
        columns = {
          {
            x = -1794,
            z = -1717
          },
          {
            x = -1794,
            z = -1716
          },
          {
            x = -1794,
            z = -1715
          },
          {
            x = -1794,
            z = -1714
          }
        },
        direction = {
          x = -1,
          z = 0
        },
        length = 4,
        profile = {
          {
            y = 10,
            name = "mcl_stairs:slab_cobble",
            param2 = 0
          },
          {
            y = 9,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 9,
            name = "mcl_core:cobble",
            param2 = 0
          },
          {
            y = 9,
            name = "mcl_core:cobble",
            param2 = 0
          }
        },
        source = "wall_gatehouse"
      }
    },
    reservation = {
      max = {
        x = -1465,
        y = 152,
        z = -1471
      },
      min = {
        x = -1955,
        y = -117,
        z = -1961
      }
    },
    site_id = "2:-2:-2:0:medieval:45585845:-1710:-1716",
    state = "complete",
    structures = {
      {
        x1 = -1845,
        x2 = -1838,
        z1 = -1688,
        z2 = -1680
      },
      {
        x1 = -1841,
        x2 = -1834,
        z1 = -1740,
        z2 = -1732
      },
      {
        x1 = -1829,
        x2 = -1822,
        z1 = -1660,
        z2 = -1652
      },
      {
        x1 = -1811,
        x2 = -1799,
        z1 = -1826,
        z2 = -1810
      },
      {
        x1 = -1811,
        x2 = -1799,
        z1 = -1697,
        z2 = -1681
      },
      {
        x1 = -1809,
        x2 = -1797,
        z1 = -1753,
        z2 = -1737
      },
      {
        x1 = -1793,
        x2 = -1785,
        z1 = -1723,
        z2 = -1708
      },
      {
        x1 = -1791,
        x2 = -1784,
        z1 = -1765,
        z2 = -1758
      },
      {
        x1 = -1791,
        x2 = -1784,
        z1 = -1673,
        z2 = -1666
      },
      {
        x1 = -1789,
        x2 = -1787,
        z1 = -1749,
        z2 = -1740
      },
      {
        x1 = -1789,
        x2 = -1787,
        z1 = -1687,
        z2 = -1678
      },
      {
        x1 = -1784,
        x2 = -1768,
        z1 = -1658,
        z2 = -1646
      },
      {
        x1 = -1766,
        x2 = -1759,
        z1 = -1853,
        z2 = -1845
      },
      {
        x1 = -1765,
        x2 = -1759,
        z1 = -1672,
        z2 = -1666
      },
      {
        x1 = -1739,
        x2 = -1733,
        z1 = -1672,
        z2 = -1666
      },
      {
        x1 = -1733,
        x2 = -1726,
        z1 = -1824,
        z2 = -1817
      },
      {
        x1 = -1717,
        x2 = -1702,
        z1 = -1672,
        z2 = -1664
      },
      {
        x1 = -1714,
        x2 = -1698,
        z1 = -1842,
        z2 = -1830
      },
      {
        x1 = -1704,
        x2 = -1698,
        z1 = -1824,
        z2 = -1818
      },
      {
        x1 = -1698,
        x2 = -1690,
        z1 = -1621,
        z2 = -1614
      },
      {
        x1 = -1685,
        x2 = -1679,
        z1 = -1672,
        z2 = -1666
      },
      {
        x1 = -1679,
        x2 = -1663,
        z1 = -1659,
        z2 = -1647
      },
      {
        x1 = -1678,
        x2 = -1671,
        z1 = -1824,
        z2 = -1817
      },
      {
        x1 = -1659,
        x2 = -1653,
        z1 = -1672,
        z2 = -1666
      },
      {
        x1 = -1635,
        x2 = -1628,
        z1 = -1673,
        z2 = -1666
      },
      {
        x1 = -1633,
        x2 = -1617,
        z1 = -1843,
        z2 = -1831
      },
      {
        x1 = -1610,
        x2 = -1594,
        z1 = -1660,
        z2 = -1648
      },
      {
        x1 = -1581,
        x2 = -1574,
        z1 = -1744,
        z2 = -1737
      },
      {
        x1 = -1581,
        x2 = -1574,
        z1 = -1694,
        z2 = -1687
      },
      {
        x1 = -1580,
        x2 = -1574,
        z1 = -1718,
        z2 = -1712
      },
      {
        x1 = -1568,
        x2 = -1556,
        z1 = -1771,
        z2 = -1755
      },
      {
        x1 = -1568,
        x2 = -1556,
        z1 = -1724,
        z2 = -1708
      },
      {
        x1 = -1567,
        x2 = -1555,
        z1 = -1688,
        z2 = -1672
      },
      {
        x1 = -1530,
        x2 = -1523,
        z1 = -1855,
        z2 = -1847
      }
    },
    town_type = "medieval"
  }
}
