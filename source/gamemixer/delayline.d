/**
* Delay-line implementation.
* Copyright: Guillaume Piolat 2015-2021.
* License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module gamemixer.delayline;

import core.stdc.string;

import dplug.core.nogc;
import dplug.core.math;
import dplug.core.vec;

nothrow @nogc:

/// Allow to sample signal back in time.
/// This delay-line has a twin write index, so that the read pointer 
/// can read a contiguous memory area.
/// ____________________________________________________________________________________
/// |     | _index |                  | readPointer = _index + half size |             |
/// ------------------------------------------------------------------------------------
///
struct Delayline(T)
{
public:
nothrow:
@nogc:

    /// Initialize the delay line. Can delay up to count samples.
    void initialize(int numSamples)
    {
        resize(numSamples);
    }

    ~this()
    {
        _data.reallocBuffer(0);
    }

    @disable this(this);

    /// Resize the delay line. Can delay up to count samples.
    /// The state is cleared.
    void resize(int numSamples)
    {
        if (numSamples < 0)
            assert(false);

        // Over-allocate to support POW2 delaylines.
        // This wastes memory but allows delay-line of length 0 without tests.

        int toAllocate = nextPow2HigherOrEqual(numSamples + 1);
        _data.reallocBuffer(toAllocate * 2);
        _half = toAllocate;
        _indexMask = toAllocate - 1;
        _numSamples = numSamples;
        _index = _indexMask;

        _data[] = 0;
    }

    /// Combined feed + sampleFull.
    /// Uses the delay line as a fixed delay of count samples.
    T nextSample(T incoming) pure
    {
        feedSample(incoming);
        return sampleFull(_numSamples);
    }

    /// Combined feed + sampleFull.
    /// Uses the delay line as a fixed delay of count samples.
    ///
    /// Note: input and output may overlap. 
    ///       If this was ever optimized, this should preserve that property.
    void nextBuffer(const(T)* input, T* output, int frames) pure
    {
        for(int i = 0; i < frames; ++i)
            output[i] = nextSample(input[i]);
    }

    /// Adds a new sample at end of delay.
    void feedSample(T incoming) pure
    {
        _index = (_index + 1) & _indexMask;
        _data.ptr[_index] = incoming;
        _data.ptr[_index + _half] = incoming;
    }

    /// Adds several samples at end of delay.
    void feedBuffer(const(T)[] incoming) pure
    {
        int N = cast(int)(incoming.length);

        // this buffer must be smaller than the delay line, 
        // else we may risk dropping samples immediately
        assert(N < _numSamples);

        // remaining samples before end of delayline
        int remain = _indexMask - _index;

        if (N <= remain)
        {
            memcpy( &_data[_index + 1], incoming.ptr, N * T.sizeof );
            memcpy( &_data[_index + 1 + _half], incoming.ptr, N * T.sizeof );
            _index += N;
        }
        else
        {
            memcpy( _data.ptr + (_index + 1), incoming.ptr, remain * T.sizeof );
            memcpy( _data.ptr + (_index + 1) + _half, incoming.ptr, remain * T.sizeof );
            size_t numBytes = (N - remain) * T.sizeof;
            memcpy( _data.ptr, incoming.ptr + remain, numBytes);
            memcpy( _data.ptr + _half, incoming.ptr + remain, numBytes);
            _index = (_index + N) & _indexMask;
        }
    }

    /// Returns: A pointer which allow to get delayed values.
    ///    readPointer()[0] is the last samples fed,  readPointer()[-1] is the penultimate.
    /// Warning: it goes backwards, increasing delay => decreasing addressed.
    const(T)* readPointer() pure const
    {
        return _data.ptr + _index + _half;
    }

    /// Random access sampling of the delay-line at integer points.
    /// Delay 0 = last entered sample with feed().
    T sampleFull(int delay) pure
    {
        assert(delay >= 0);
        return readPointer()[-delay];
    }

    /// Random access sampling of the delay-line at integer points, extract a time slice.
    /// Delay 0 = last entered sample with feed().
    void sampleFullBuffer(int delayOfMostRecentSample, float* outBuffer, int frames) pure
    {
        assert(delayOfMostRecentSample >= 0);
        const(T*) p = readPointer();
        const(T*) source = &readPointer[-delayOfMostRecentSample - frames + 1];
        size_t numBytes = frames * T.sizeof;
        memcpy(outBuffer, source, numBytes);
    }

    static if (is(T == float) || is(T == double))
    {
        /// Random access sampling of the delay-line with linear interpolation.
        T sampleLinear(float delay) pure const
        {
            assert(delay > 0);
            int iPart;
            float fPart;
            decomposeFractionalDelay(delay, iPart, fPart);
            const(T)* pData = readPointer();
            T x0  = pData[iPart];
            T x1  = pData[iPart + 1];
            return lerp(x0, x1, fPart);
        }

        /// Random access sampling of the delay-line with a 3rd order polynomial.
        T sampleHermite(float delay) pure const
        {
            assert(delay > 1);
            int iPart;
            float fPart;
            decomposeFractionalDelay(delay, iPart, fPart);
            const(T)* pData = readPointer();
            T xm1 = pData[iPart-1];
            T x0  = pData[iPart  ];
            T x1  = pData[iPart+1];
            T x2  = pData[iPart+2];
            return hermiteInterp!T(fPart, xm1, x0, x1, x2);
        }

        /// Third-order spline interpolation
        /// http://musicdsp.org/showArchiveComment.php?ArchiveID=62
        T sampleSpline3(float delay) pure const
        {
            assert(delay > 1);
            int iPart;
            float fPart;
            decomposeFractionalDelay(delay, iPart, fPart);
            assert(fPart >= 0.0f);
            assert(fPart <= 1.0f);
            const(T)* pData = readPointer();
            T L1 = pData[iPart-1];
            T L0  = pData[iPart  ];
            T H0  = pData[iPart+1];
            T H1  = pData[iPart+2];

            return L0 + 0.5f *
                fPart*(H0-L1 +
                fPart*(H0 + L0*(-2) + L1 +
                fPart*( (H0 - L0)*9 + (L1 - H1)*3 +
                fPart*((L0 - H0)*15 + (H1 - L1)*5 +
                fPart*((H0 - L0)*6 + (L1 - H1)*2 )))));
        }

        /// 4th order spline interpolation
        /// http://musicdsp.org/showArchiveComment.php?ArchiveID=60
        T sampleSpline4(float delay) pure const
        {
            assert(delay > 2);
            int iPart;
            float fPart;
            decomposeFractionalDelay(delay, iPart, fPart);

            align(16) __gshared static immutable float[8][5] MAT = 
            [
                [  2.0f / 24, -16.0f / 24,   0.0f / 24,   16.0f / 24,  -2.0f / 24,   0.0f / 24, 0.0f, 0.0f ],
                [ -1.0f / 24,  16.0f / 24, -30.0f / 24,   16.0f / 24,  -1.0f / 24,   0.0f / 24, 0.0f, 0.0f ],
                [ -9.0f / 24,  39.0f / 24, -70.0f / 24,   66.0f / 24, -33.0f / 24,   7.0f / 24, 0.0f, 0.0f ],
                [ 13.0f / 24, -64.0f / 24, 126.0f / 24, -124.0f / 24,  61.0f / 24, -12.0f / 24, 0.0f, 0.0f ],
                [ -5.0f / 24,  25.0f / 24, -50.0f / 24,   50.0f / 24, -25.0f / 24,   5.0f / 24, 0.0f, 0.0f ]
            ];
            import inteli.emmintrin;
            __m128 pFactor0_3 = _mm_setr_ps(0.0f, 0.0f, 1.0f, 0.0f);
            __m128 pFactor4_7 = _mm_setzero_ps();

            __m128 XMM_fPart = _mm_set1_ps(fPart);
            __m128 weight = XMM_fPart;
            pFactor0_3 = _mm_add_ps(pFactor0_3, _mm_load_ps(&MAT[0][0]) * weight);
            pFactor4_7 = _mm_add_ps(pFactor4_7, _mm_load_ps(&MAT[0][4]) * weight);
            weight = _mm_mul_ps(weight, XMM_fPart);
            pFactor0_3 = _mm_add_ps(pFactor0_3, _mm_load_ps(&MAT[1][0]) * weight);
            pFactor4_7 = _mm_add_ps(pFactor4_7, _mm_load_ps(&MAT[1][4]) * weight);
            weight = _mm_mul_ps(weight, XMM_fPart);
            pFactor0_3 = _mm_add_ps(pFactor0_3, _mm_load_ps(&MAT[2][0]) * weight);
            pFactor4_7 = _mm_add_ps(pFactor4_7, _mm_load_ps(&MAT[2][4]) * weight);
            weight = _mm_mul_ps(weight, XMM_fPart);
            pFactor0_3 = _mm_add_ps(pFactor0_3, _mm_load_ps(&MAT[3][0]) * weight);
            pFactor4_7 = _mm_add_ps(pFactor4_7, _mm_load_ps(&MAT[3][4]) * weight);
            weight = _mm_mul_ps(weight, XMM_fPart);
            pFactor0_3 = _mm_add_ps(pFactor0_3, _mm_load_ps(&MAT[4][0]) * weight);
            pFactor4_7 = _mm_add_ps(pFactor4_7, _mm_load_ps(&MAT[4][4]) * weight);

            float[8] pfactor = void;
            _mm_storeu_ps(&pfactor[0], pFactor0_3); 
            _mm_storeu_ps(&pfactor[4], pFactor4_7);

            T result = 0;
            const(T)* pData = readPointer();
            foreach(n; 0..6)
                result += pData[iPart-2 + n] * pfactor[n];
            return result;
        };
    }

private:
    T[] _data;
    int _index;
    int _half; // half the size of the data
    int _indexMask;
    int _numSamples;

    void decomposeFractionalDelay(float delay, 
                                  out int outIntegerPart, 
                                  out float outFloatPart) pure const
    {
        // Because float index can yield suprising low precision with interpolation  
        // So we up the precision to double in order to have a precise fractional part          
        int offset = cast(int)(_data.length);
        double doubleDelayMinus = cast(double)(-delay);
        int iPart = cast(int)(doubleDelayMinus + offset);
        iPart -= offset;
        float fPart = cast(float)(doubleDelayMinus - iPart);
        assert(fPart >= 0.0f);
        assert(fPart <= 1.0f);
        outIntegerPart = iPart;
        outFloatPart = fPart;
    }
}

unittest
{
    Delayline!float line;
    line.initialize(0); // should be possible
    assert(line.nextSample(1) == 1);

    Delayline!double line2;

    Delayline!float line3;
    line3.initialize(2);
    assert(line3.nextSample(1) == 0);
    assert(line3.nextSample(2) == 0);
    assert(line3.nextSample(3) == 1);
    assert(line3.nextSample(42) == 2);

    assert(line3.sampleFull(0) == 42);
    assert(line3.sampleFull(1) == 3);
    assert(line3.sampleLinear(0.5f) == (3.0f + 42.0f) * 0.5f);
}

