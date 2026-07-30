from std.benchmark import Bench, BenchConfig, Bencher, keep, BenchId

from custom_benchmark import DefaultBench

from larecs.test_utils import *
from larecs.component import ComponentManager

comptime FullManager = ComponentManager[
    FlexibleComponent[0],
    FlexibleComponent[1],
    FlexibleComponent[2],
    FlexibleComponent[3],
    FlexibleComponent[4],
    FlexibleComponent[5],
    FlexibleComponent[6],
    FlexibleComponent[7],
    FlexibleComponent[8],
    FlexibleComponent[9],
    FlexibleComponent[10],
    FlexibleComponent[11],
    FlexibleComponent[12],
    FlexibleComponent[13],
    FlexibleComponent[14],
    FlexibleComponent[15],
    FlexibleComponent[16],
    FlexibleComponent[17],
    FlexibleComponent[18],
    FlexibleComponent[19],
    FlexibleComponent[20],
    FlexibleComponent[21],
    FlexibleComponent[22],
    FlexibleComponent[23],
    FlexibleComponent[24],
    FlexibleComponent[25],
    FlexibleComponent[26],
    FlexibleComponent[27],
    FlexibleComponent[28],
    FlexibleComponent[29],
    FlexibleComponent[30],
    FlexibleComponent[31],
    FlexibleComponent[32],
    FlexibleComponent[33],
    FlexibleComponent[34],
    FlexibleComponent[35],
    FlexibleComponent[36],
    FlexibleComponent[37],
    FlexibleComponent[38],
    FlexibleComponent[39],
    FlexibleComponent[40],
    FlexibleComponent[41],
    FlexibleComponent[42],
    FlexibleComponent[43],
    FlexibleComponent[44],
    FlexibleComponent[45],
    FlexibleComponent[46],
    FlexibleComponent[47],
    FlexibleComponent[48],
    FlexibleComponent[49],
    FlexibleComponent[50],
    FlexibleComponent[51],
    FlexibleComponent[52],
    FlexibleComponent[53],
    FlexibleComponent[54],
    FlexibleComponent[55],
    FlexibleComponent[56],
    FlexibleComponent[57],
    FlexibleComponent[58],
    FlexibleComponent[59],
    FlexibleComponent[60],
    FlexibleComponent[61],
    FlexibleComponent[62],
    FlexibleComponent[63],
    FlexibleComponent[64],
    FlexibleComponent[65],
    FlexibleComponent[66],
    FlexibleComponent[67],
    FlexibleComponent[68],
    FlexibleComponent[69],
    FlexibleComponent[70],
    FlexibleComponent[71],
    FlexibleComponent[72],
    FlexibleComponent[73],
    FlexibleComponent[74],
    FlexibleComponent[75],
    FlexibleComponent[76],
    FlexibleComponent[77],
    FlexibleComponent[78],
    FlexibleComponent[79],
    FlexibleComponent[80],
    FlexibleComponent[81],
    FlexibleComponent[82],
    FlexibleComponent[83],
    FlexibleComponent[84],
    FlexibleComponent[85],
    FlexibleComponent[86],
    FlexibleComponent[87],
    FlexibleComponent[88],
    FlexibleComponent[89],
    FlexibleComponent[90],
    FlexibleComponent[91],
    FlexibleComponent[92],
    FlexibleComponent[93],
    FlexibleComponent[94],
    FlexibleComponent[95],
    FlexibleComponent[96],
    FlexibleComponent[97],
    FlexibleComponent[98],
    FlexibleComponent[99],
    FlexibleComponent[100],
    FlexibleComponent[101],
    FlexibleComponent[102],
    FlexibleComponent[103],
    FlexibleComponent[104],
    FlexibleComponent[105],
    FlexibleComponent[106],
    FlexibleComponent[107],
    FlexibleComponent[108],
    FlexibleComponent[109],
    FlexibleComponent[110],
    FlexibleComponent[111],
    FlexibleComponent[112],
    FlexibleComponent[113],
    FlexibleComponent[114],
    FlexibleComponent[115],
    FlexibleComponent[116],
    FlexibleComponent[117],
    FlexibleComponent[118],
    FlexibleComponent[119],
    FlexibleComponent[120],
    FlexibleComponent[121],
    FlexibleComponent[122],
    FlexibleComponent[123],
    FlexibleComponent[124],
    FlexibleComponent[125],
    FlexibleComponent[126],
    FlexibleComponent[127],
    FlexibleComponent[128],
    FlexibleComponent[129],
    FlexibleComponent[130],
    FlexibleComponent[131],
    FlexibleComponent[132],
    FlexibleComponent[133],
    FlexibleComponent[134],
    FlexibleComponent[135],
    FlexibleComponent[136],
    FlexibleComponent[137],
    FlexibleComponent[138],
    FlexibleComponent[139],
    FlexibleComponent[140],
    FlexibleComponent[141],
    FlexibleComponent[142],
    FlexibleComponent[143],
    FlexibleComponent[144],
    FlexibleComponent[145],
    FlexibleComponent[146],
    FlexibleComponent[147],
    FlexibleComponent[148],
    FlexibleComponent[149],
    FlexibleComponent[150],
    FlexibleComponent[151],
    FlexibleComponent[152],
    FlexibleComponent[153],
    FlexibleComponent[154],
    FlexibleComponent[155],
    FlexibleComponent[156],
    FlexibleComponent[157],
    FlexibleComponent[158],
    FlexibleComponent[159],
    FlexibleComponent[160],
    FlexibleComponent[161],
    FlexibleComponent[162],
    FlexibleComponent[163],
    FlexibleComponent[164],
    FlexibleComponent[165],
    FlexibleComponent[166],
    FlexibleComponent[167],
    FlexibleComponent[168],
    FlexibleComponent[169],
    FlexibleComponent[170],
    FlexibleComponent[171],
    FlexibleComponent[172],
    FlexibleComponent[173],
    FlexibleComponent[174],
    FlexibleComponent[175],
    FlexibleComponent[176],
    FlexibleComponent[177],
    FlexibleComponent[178],
    FlexibleComponent[179],
    FlexibleComponent[180],
    FlexibleComponent[181],
    FlexibleComponent[182],
    FlexibleComponent[183],
    FlexibleComponent[184],
    FlexibleComponent[185],
    FlexibleComponent[186],
    FlexibleComponent[187],
    FlexibleComponent[188],
    FlexibleComponent[189],
    FlexibleComponent[190],
    FlexibleComponent[191],
    FlexibleComponent[192],
    FlexibleComponent[193],
    FlexibleComponent[194],
    FlexibleComponent[195],
    FlexibleComponent[196],
    FlexibleComponent[197],
    FlexibleComponent[198],
    FlexibleComponent[199],
    FlexibleComponent[200],
    FlexibleComponent[201],
    FlexibleComponent[202],
    FlexibleComponent[203],
    FlexibleComponent[204],
    FlexibleComponent[205],
    FlexibleComponent[206],
    FlexibleComponent[207],
    FlexibleComponent[208],
    FlexibleComponent[209],
    FlexibleComponent[210],
    FlexibleComponent[211],
    FlexibleComponent[212],
    FlexibleComponent[213],
    FlexibleComponent[214],
    FlexibleComponent[215],
    FlexibleComponent[216],
    FlexibleComponent[217],
    FlexibleComponent[218],
    FlexibleComponent[219],
    FlexibleComponent[220],
    FlexibleComponent[221],
    FlexibleComponent[222],
    FlexibleComponent[223],
    FlexibleComponent[224],
    FlexibleComponent[225],
    FlexibleComponent[226],
    FlexibleComponent[227],
    FlexibleComponent[228],
    FlexibleComponent[229],
    FlexibleComponent[230],
    FlexibleComponent[231],
    FlexibleComponent[232],
    FlexibleComponent[233],
    FlexibleComponent[234],
    FlexibleComponent[235],
    FlexibleComponent[236],
    FlexibleComponent[237],
    FlexibleComponent[238],
    FlexibleComponent[239],
    FlexibleComponent[240],
    FlexibleComponent[241],
    FlexibleComponent[242],
    FlexibleComponent[243],
    FlexibleComponent[244],
    FlexibleComponent[245],
    FlexibleComponent[246],
    FlexibleComponent[247],
    FlexibleComponent[248],
    FlexibleComponent[249],
    FlexibleComponent[250],
    FlexibleComponent[251],
    FlexibleComponent[252],
    FlexibleComponent[253],
    FlexibleComponent[254],
    FlexibleComponent[255],
]


def benchmark_get_first_id_1_000_000(mut bencher: Bencher):
    # create a component manager with 256 components

    @always_inline
    def bench_fn() {imm}:
        for _ in range(1_000_000):
            keep(FullManager.get_id[FlexibleComponent[0]]())

    bencher.iter(bench_fn)


def benchmark_get_last_id_1_000_000(mut bencher: Bencher):
    # create a component manager with 256 components

    @always_inline
    def bench_fn() {imm}:
        for _ in range(1_000_000):
            keep(FullManager.get_id[FlexibleComponent[255]]())

    bencher.iter(bench_fn)


def t[size: Int](arr: InlineArray[UInt8, size]) -> UInt8:
    return arr[0]


def benchmark_get_5_id_arr_1_000_000(mut bencher: Bencher):
    # create a component manager with 256 components

    @always_inline
    def bench_fn() {imm}:
        for _ in range(1_000_000):
            arr = FullManager.get_id_arr[
                FlexibleComponent[1],
                FlexibleComponent[0],
                FlexibleComponent[2],
                FlexibleComponent[3],
                FlexibleComponent[4],
            ]()
            keep(arr[0])

    bencher.iter(bench_fn)


def run_all_component_benchmarks() raises:
    bench = DefaultBench()
    run_all_component_benchmarks(bench)
    bench.dump_report()


def run_all_component_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_get_first_id_1_000_000, BenchId("10^6 * component_get_id[0]")
    )
    bench.bench_function(
        benchmark_get_last_id_1_000_000, BenchId("10^6 * component_get_id[255]")
    )
    bench.bench_function(
        benchmark_get_5_id_arr_1_000_000,
        BenchId("10^6 * component_get_id_arr (5 components)"),
    )


def main() raises:
    run_all_component_benchmarks()
